#!/usr/bin/env python3
"""Strip a real radio's private data from a capture before it is committed (#784).

A capture from capture_trace.py holds the radio's own key, name and position,
every contact's key, name, path, position and advert times, and every
channel's name and secret. This rewrites each of those to a stand-in and
leaves everything else byte for byte, so the fake radio still has to match
the real firmware.

  python tool/fake_radio/anonymize_trace.py capture.json test/fake_radio/traces/x.json

Stand-ins are numbered or random, never derived from the real values: a hash
of a public key could be matched against keys heard on the air, and real
advert times could be matched against a public observer's log. The Public
channel keeps its name and its published secret. Pushes are dropped (replay
ignores them, and an advert or message push would carry someone's data).

Fail-closed: a reply type this script does not know, or a custom variable it
has not been told is safe, stops it. Extend it before committing that capture.
"""
import json
import random
import re
import sys

RESP_ERR = 1
RESP_CONTACTS_START = 2
RESP_CONTACT = 3
RESP_END_OF_CONTACTS = 4
RESP_SELF_INFO = 5
RESP_CURR_TIME = 9
RESP_BATT_AND_STORAGE = 12
RESP_DEVICE_INFO = 13
RESP_CHANNEL_INFO = 18
RESP_CUSTOM_VARS = 21
RESP_AUTOADD_CONFIG = 25
OFFBAND_GPS = 0xC1
OFFBAND_BLOCK = 0xC2
OFFBAND_PKT_HASH = 0xC6

# Replies that carry nothing about the owner: kept as they are. DEVICE_INFO
# holds the firmware version, build date and board name, which are the same
# for every radio running that build.
UNCHANGED = {
    0,
    RESP_ERR,
    RESP_CONTACTS_START,
    RESP_CURR_TIME,
    RESP_BATT_AND_STORAGE,
    RESP_DEVICE_INFO,
    RESP_AUTOADD_CONFIG,
    OFFBAND_PKT_HASH,
}
# Custom variables known to hold no personal data (MyMesh.cpp custom vars).
SAFE_CUSTOM_VARS = {"gps"}

PUBLIC_SECRET = bytes.fromhex("8b3387e9c5cdea6ac9e5edbaa115cd72")
TYPE_NAMES = {1: "Contact", 2: "Repeater", 3: "Room", 4: "Sensor"}
GPS_NUMBERS = re.compile(r"\b(lat|lon|alt_cm|time)=(-?\d+)")
STAND_IN_EPOCH = 1_790_000_000  # 2026-09-21, the fake clock's default


def put_name(frame, at, width, name):
    raw = name.encode()[: width - 1]
    frame[at:at + width] = raw + bytes(width - len(raw))


def put_u32(frame, at, value, signed=False):
    frame[at:at + 4] = value.to_bytes(4, "little", signed=signed)


def get_u32(frame, at, signed=False):
    return int.from_bytes(frame[at:at + 4], "little", signed=signed)


class Anonymizer:
    def __init__(self):
        self.rng = random.Random(755)
        self.keys = {}
        self.counts = {}
        self.newest_lastmod = 0

    def key(self, real):
        # The same real key gets the same stand-in, so a blocked contact
        # still matches its contact entry.
        if real not in self.keys:
            self.keys[real] = bytes(self.rng.randrange(256) for _ in range(32))
        return self.keys[real]

    def position(self, frame, at):
        # A zero position means "none" to the client; keep that meaning.
        if get_u32(frame, at) == 0 and get_u32(frame, at + 4) == 0:
            return
        put_u32(frame, at, 45_000_000 + self.rng.randrange(-500_000, 500_000), True)
        put_u32(frame, at + 4, -100_000_000 + self.rng.randrange(-500_000, 500_000), True)

    def stand_in_time(self, frame, at):
        # Zero keeps its meaning (a lastmod of 0 is never sent).
        if get_u32(frame, at) == 0:
            return 0
        t = STAND_IN_EPOCH + self.rng.randrange(0, 30 * 86400)
        put_u32(frame, at, t)
        return t

    def numbered(self, kind):
        self.counts[kind] = self.counts.get(kind, 0) + 1
        return f"{kind} {self.counts[kind]:03d}"

    def frame(self, f):
        if not f:
            return f
        code = f[0]
        if code in UNCHANGED:
            pass
        elif code == RESP_SELF_INFO and len(f) >= 58:
            f[4:36] = self.key(bytes(f[4:36]))
            self.position(f, 36)
            f[58:] = b"Trace Radio"
        elif code == RESP_CONTACT and len(f) >= 148:
            f[1:33] = self.key(bytes(f[1:33]))
            # Every byte of the 64-byte path field, including what firmware
            # leaves past the path's end, becomes an independent random byte.
            # Zeros stay zero so the field's shape is kept.
            for i in range(36, 100):
                if f[i]:
                    f[i] = self.rng.randrange(1, 256)
            put_name(f, 100, 32, self.numbered(TYPE_NAMES.get(f[33], "Node")))
            self.stand_in_time(f, 132)  # last_advert
            self.position(f, 136)
            self.newest_lastmod = max(self.newest_lastmod, self.stand_in_time(f, 144))
        elif code == RESP_END_OF_CONTACTS and len(f) >= 5:
            # The newest lastmod among the contacts sent (MyMesh.cpp), so the
            # stand-in times stay consistent with it.
            put_u32(f, 1, self.newest_lastmod)
            self.newest_lastmod = 0
        elif code == RESP_CHANNEL_INFO and len(f) >= 50:
            name_end = f.index(0, 2) if 0 in f[2:34] else 34
            secret = bytes(f[34:50])
            if secret == PUBLIC_SECRET and bytes(f[2:name_end]) == b"Public":
                put_name(f, 2, 32, "Public")
            elif f[2] == 0 and not any(secret):
                f[2:34] = bytes(32)  # an empty slot; clear leftover name bytes
            else:
                put_name(f, 2, 32, self.numbered("Channel"))
                f[34:50] = bytes(self.rng.randrange(256) for _ in range(16))
        elif code == RESP_CUSTOM_VARS:
            text = bytes(f[1:]).decode("utf-8", "replace")
            names = {p.split(":", 1)[0] for p in text.split(",") if ":" in p}
            unknown = names - SAFE_CUSTOM_VARS
            if unknown:
                sys.exit(f"custom variable(s) not known to be safe: {sorted(unknown)}")
        elif code == OFFBAND_GPS:
            text = bytes(f[1:]).decode("utf-8", "replace")
            fake = {"lat": "45000000", "lon": "-100000000", "alt_cm": "10000", "time": str(STAND_IN_EPOCH)}
            text = GPS_NUMBERS.sub(
                lambda m: m.group(0) if m.group(2) == "0" else f"{m.group(1)}={fake[m.group(1)]}", text
            )
            f[1:] = text.encode()
        elif code == OFFBAND_BLOCK:
            if len(f) >= 35 and f[2] < 0xFE:
                f[3:35] = self.key(bytes(f[3:35]))
        else:
            sys.exit(f"reply code {code:#04x} is not handled: extend anonymize_trace.py first")
        return f


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: anonymize_trace.py <capture.json> <out.json>")
    with open(sys.argv[1], encoding="utf-8") as f:
        trace = json.load(f)
    anon = Anonymizer()
    for step in trace["steps"]:
        step["replies"] = [anon.frame(bytearray.fromhex(r)).hex() for r in step["replies"]]
        step["pushes"] = []
    trace["anonymized"] = True
    with open(sys.argv[2], "w", encoding="utf-8") as f:
        json.dump(trace, f, indent=1)
        f.write("\n")
    print(f"{len(anon.keys)} keys, {sum(anon.counts.values())} names replaced -> {sys.argv[2]}")


if __name__ == "__main__":
    main()

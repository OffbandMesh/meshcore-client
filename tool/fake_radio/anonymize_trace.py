#!/usr/bin/env python3
"""Strip a real radio's private data from a capture before it is committed (#784).

A capture from capture_trace.py holds the radio's own key, name and position,
every contact's key, name, path and position, and every channel's name and
secret. This rewrites each of those to a stand-in and leaves everything else
byte for byte, so the fake radio still has to match the real firmware.

  python tool/fake_radio/anonymize_trace.py capture.json test/fake_radio/traces/x.json

Stand-ins are numbered, not derived from the real values: a hash of a public
key could be matched against keys heard on the air. The Public channel keeps
its name and its published secret. Pushes are dropped (replay ignores them,
and an advert or message push would carry someone's data).
"""
import json
import random
import sys

RESP_SELF_INFO = 5
RESP_CONTACT = 3
RESP_CHANNEL_INFO = 18
OFFBAND_BLOCK = 0xC2
PUBLIC_SECRET = bytes.fromhex("8b3387e9c5cdea6ac9e5edbaa115cd72")
TYPE_NAMES = {1: "Contact", 2: "Repeater", 3: "Room", 4: "Sensor"}


def put_name(frame, at, width, name):
    raw = name.encode()[: width - 1]
    frame[at:at + width] = raw + bytes(width - len(raw))


def put_i32(frame, at, value):
    frame[at:at + 4] = value.to_bytes(4, "little", signed=True)


def get_i32(frame, at):
    return int.from_bytes(frame[at:at + 4], "little", signed=True)


class Anonymizer:
    def __init__(self):
        self.rng = random.Random(755)
        self.keys = {}
        self.path_bytes = {}
        self.counts = {}

    def key(self, real):
        if real not in self.keys:
            self.keys[real] = bytes(self.rng.randrange(256) for _ in range(32))
        return self.keys[real]

    def hop(self, real):
        if real not in self.path_bytes:
            self.path_bytes[real] = self.rng.randrange(256)
        return self.path_bytes[real]

    def position(self, frame, at):
        # A zero position means "none" to the client; keep that meaning.
        if get_i32(frame, at) == 0 and get_i32(frame, at + 4) == 0:
            return
        put_i32(frame, at, 45_000_000 + self.rng.randrange(-500_000, 500_000))
        put_i32(frame, at + 4, -100_000_000 + self.rng.randrange(-500_000, 500_000))

    def numbered(self, kind):
        self.counts[kind] = self.counts.get(kind, 0) + 1
        return f"{kind} {self.counts[kind]:03d}"

    def frame(self, f):
        if not f:
            return f
        if f[0] == RESP_SELF_INFO and len(f) >= 58:
            f[4:36] = self.key(bytes(f[4:36]))
            self.position(f, 36)
            raw = b"Trace Radio"
            f[58:] = raw
        elif f[0] == RESP_CONTACT and len(f) >= 148:
            f[1:33] = self.key(bytes(f[1:33]))
            path_len = f[35]
            if path_len != 0xFF:
                # Low 6 bits count hops, high 2 bits size each hop's hash.
                used = (path_len & 0x3F) * ((path_len >> 6) + 1)
                for i in range(36, 36 + min(used, 64)):
                    f[i] = self.hop(f[i])
            put_name(f, 100, 32, self.numbered(TYPE_NAMES.get(f[33], "Node")))
            self.position(f, 136)
        elif f[0] == RESP_CHANNEL_INFO and len(f) >= 50:
            name_end = f.index(0, 2) if 0 in f[2:34] else 34
            secret = bytes(f[34:50])
            if secret == PUBLIC_SECRET and bytes(f[2:name_end]) == b"Public":
                put_name(f, 2, 32, "Public")
            elif f[2] == 0 and not any(secret):
                f[2:34] = bytes(32)  # an empty slot; clear leftover name bytes
            else:
                put_name(f, 2, 32, self.numbered("Channel"))
                f[34:50] = bytes(self.rng.randrange(256) for _ in range(16))
        elif f[0] == OFFBAND_BLOCK and len(f) >= 35 and f[2] < 0xFE:
            f[3:35] = self.key(bytes(f[3:35]))
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

"""Read-only bench check of a real radio for the forced contact resync (#703).

Run with the app disconnected from the radio (the serial port is exclusive):

    python tools/contact_recovery_bench.py COM13
    python tools/contact_recovery_bench.py COM13 --expect-key d549bbfbd0

Sends only APP_START, CMD_GET_CONTACTS and CMD_GET_CONTACT_BY_KEY; it never
writes to the radio's contact table. It checks the two protocol facts the
recovery relies on, on the real firmware:

1. A by-key request for a contact the radio holds returns that contact.
2. A by-key request for a key it does not hold returns ERR_CODE_NOT_FOUND (2).

and reports how full syncs (up to --pulls, paced by --settle) add up against
the declared total. Exit code 0 when both protocol checks pass.
"""
import argparse
import os
import sys
import time

import serial

CMD_APP_START = 0x01
CMD_GET_CONTACTS = 0x04
CMD_GET_CONTACT_BY_KEY = 30
RESP_ERR = 0x01
RESP_CONTACTS_START = 0x02
RESP_CONTACT = 0x03
RESP_END_OF_CONTACTS = 0x04
RESP_SELF_INFO = 0x05
ERR_NOT_FOUND = 2


def frame(payload: bytes) -> bytes:
    return bytes([0x3C, len(payload) & 0xFF, len(payload) >> 8]) + payload


class Reader:
    def __init__(self, ser):
        self.ser = ser
        self.buf = bytearray()
        self.skipped = 0

    def frames(self, timeout):
        end = time.time() + timeout
        while time.time() < end:
            chunk = self.ser.read(self.ser.in_waiting or 1)
            if chunk:
                self.buf += chunk
            while len(self.buf) >= 3:
                if self.buf[0] != 0x3E:
                    self.buf.pop(0)
                    self.skipped += 1
                    continue
                n = self.buf[1] | (self.buf[2] << 8)
                if n > 176:
                    self.buf.pop(0)
                    self.skipped += 1
                    continue
                if len(self.buf) < 3 + n:
                    break
                payload = bytes(self.buf[3:3 + n])
                del self.buf[:3 + n]
                yield payload
                end = time.time() + timeout


def pull(ser, r):
    ser.write(frame(bytes([CMD_GET_CONTACTS])))
    declared, keys = None, []
    for p in r.frames(5):
        if p[0] == RESP_CONTACTS_START and len(p) >= 5:
            declared = int.from_bytes(p[1:5], "little")
        elif p[0] == RESP_CONTACT and len(p) >= 33:
            keys.append(p[1:33].hex())
        elif p[0] == RESP_END_OF_CONTACTS:
            break
    return declared, keys


def by_key(ser, r, key_hex):
    """Returns ('contact', key) / ('err', code) / ('none', None)."""
    ser.write(frame(bytes([CMD_GET_CONTACT_BY_KEY]) + bytes.fromhex(key_hex)))
    for p in r.frames(5):
        if p[0] == RESP_CONTACT and len(p) >= 33:
            return "contact", p[1:33].hex()
        if p[0] == RESP_ERR:
            return "err", p[1] if len(p) > 1 else None
    return "none", None


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("port")
    ap.add_argument("--expect-key", help="abort unless the radio key starts with this hex")
    ap.add_argument("--pulls", type=int, default=3)
    ap.add_argument("--settle", type=float, default=10.0, help="seconds between pulls")
    args = ap.parse_args()

    ser = serial.Serial(args.port, 115200, timeout=0.05)
    try:
        time.sleep(0.5)
        ser.reset_input_buffer()
        r = Reader(ser)

        ser.write(frame(bytes([CMD_APP_START, 0x06]) + b"\x00" * 6 + b"bench703\x00"))
        key = name = None
        for p in r.frames(3):
            if p[0] == RESP_SELF_INFO and len(p) >= 36:
                key = p[4:36].hex()
                name = p[58:].split(b"\x00")[0].decode("utf-8", "replace")
                break
        if key is None:
            print(f"ABORT: no SELF_INFO from {args.port}")
            return 2
        if args.expect_key and not key.startswith(args.expect_key.lower()):
            print(f"ABORT: {args.port} is {key[:10]}, not {args.expect_key}")
            return 2
        print(f"{args.port}: {name} key={key[:10]}")

        union, declared = set(), None
        for i in range(1, args.pulls + 1):
            if i > 1:
                time.sleep(args.settle)
            declared, keys = pull(ser, r)
            union.update(keys)
            print(
                f"pull {i}: declared={declared} received={len(keys)} "
                f"union={len(union)} skipped_bytes={r.skipped}"
            )
            if declared is not None and len(union) >= declared:
                break

        ok = True
        if union:
            held = sorted(union)[0]
            kind, value = by_key(ser, r, held)
            good = kind == "contact" and value == held
            ok &= good
            print(f"by-key held contact {held[:10]}: {kind} {value!r:.24} -> {'PASS' if good else 'FAIL'}")
        else:
            print("by-key held contact: SKIP (radio delivered no contacts)")
            ok = False

        absent = os.urandom(32).hex()
        while absent in union:
            absent = os.urandom(32).hex()
        kind, value = by_key(ser, r, absent)
        good = kind == "err" and value == ERR_NOT_FOUND
        ok &= good
        print(f"by-key absent key: {kind} {value!r} -> {'PASS' if good else 'FAIL'}")

        complete = declared is not None and len(union) >= declared
        print(f"union {len(union)} of {declared}: {'complete' if complete else 'short'}")
        return 0 if ok else 1
    finally:
        ser.close()


if __name__ == "__main__":
    sys.exit(main())

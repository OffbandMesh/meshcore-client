#!/usr/bin/env python3
"""Record a real companion radio's replies to a fixed request script (#776).

Feature #755 checks the fake radio against real firmware: this talks to a
radio over USB serial, sends the same read-only requests a client sends on
connect, and writes every reply frame to a trace file. The fake radio, seeded
from the trace, must then produce the same replies.

  pip install pyserial
  python tool/fake_radio/capture_trace.py --port COM12 --label "RAK4631 offband-v1.5.0-beta7" \
      --out test/fake_radio/traces/offband-rak4631.json

Read-only by default: nothing is set or sent over the air. --drain-queue also
syncs queued messages, which REMOVES them from the radio (the app won't get
them), so only use it on a test radio.

Close the Offband app first: only one program can hold the serial port.
"""
import argparse
import datetime
import json
import sys
import time

APP_TO_RADIO = 0x3C  # '<'
RADIO_TO_APP = 0x3E  # '>'

CMD_DEVICE_QUERY = 22
CMD_APP_START = 1
CMD_GET_BATT = 20
CMD_GET_CUSTOM_VARS = 40
CMD_GET_AUTOADD = 59
CMD_GET_DEVICE_TIME = 5
CMD_GET_CONTACTS = 4
CMD_GET_CHANNEL = 31
CMD_SYNC_NEXT = 10
RESP_END_OF_CONTACTS = 4
RESP_DEVICE_INFO = 13
RESP_NO_MORE_MESSAGES = 10


class TcpLink:
    """The same framing over TCP: for checking this script against
    `dart run tool/fake_radio.dart`, or a radio with a TCP companion."""

    def __init__(self, address):
        import socket
        host, _, port = address.rpartition(":")
        self.sock = socket.create_connection((host or "127.0.0.1", int(port)), timeout=5)
        self.sock.settimeout(0.05)
        self.buf = bytearray()

    def send(self, payload):
        self.sock.sendall(bytes([APP_TO_RADIO, len(payload) & 0xFF, len(payload) >> 8]) + payload)

    def read(self, n):
        import socket
        try:
            return self.sock.recv(n)
        except socket.timeout:
            return b""

    frames = None  # bound below, shared with Link


class Link:
    def __init__(self, port, baud, dtr):
        # Set the lines before opening so pyserial doesn't pulse them. RTS stays
        # low always; DTR high suits nRF52 boards (USB-CDC writes wait for it),
        # while ESP32 USB-Serial/JTAG boards can reset into download mode on a
        # DTR change, so use --no-dtr for those (the app's #244 VID gate).
        try:
            import serial
        except ImportError:
            sys.exit("needs pyserial: pip install pyserial")
        self.port = serial.Serial()
        self.port.port = port
        self.port.baudrate = baud
        self.port.timeout = 0.05
        self.port.rts = False
        self.port.dtr = dtr
        self.port.open()
        self.buf = bytearray()
        time.sleep(1.0)
        self.port.reset_input_buffer()

    def send(self, payload):
        self.port.write(bytes([APP_TO_RADIO, len(payload) & 0xFF, len(payload) >> 8]) + payload)
        self.port.flush()

    def read(self, n):
        return self.port.read(n)

    def frames(self, quiet=0.4, until=None, limit=5.0):
        """Reply frames until [quiet] s without a frame, [until] says stop, or [limit] s."""
        out = []
        start = last = time.time()
        while time.time() - start < limit:
            self.buf += self.read(512)
            got = False
            while True:
                at = self.buf.find(bytes([RADIO_TO_APP]))
                if at < 0:
                    self.buf.clear()
                    break
                del self.buf[:at]
                if len(self.buf) < 3:
                    break
                n = self.buf[1] | (self.buf[2] << 8)
                if len(self.buf) < 3 + n:
                    break
                out.append(bytes(self.buf[3:3 + n]))
                del self.buf[:3 + n]
                got = True
                last = time.time()
                if until and until(out[-1]):
                    return out
            if not got and out and time.time() - last > quiet:
                return out
            if not got and not out and time.time() - start > max(quiet, 1.5):
                return out
        return out


TcpLink.frames = Link.frames


def is_push(frame):
    """PUSH_CODE_* are 0x80-0x9x (MyMesh.cpp:186-202). Offband replies use
    0xC0-0xCF, so they are replies, not pushes."""
    return 0x80 <= frame[0] < 0xC0


def split(frames):
    """Pushes arrive whenever the radio likes; keep them apart."""
    replies = [f for f in frames if f and not is_push(f)]
    pushes = [f for f in frames if f and is_push(f)]
    return replies, pushes


def main():
    ap = argparse.ArgumentParser()
    where = ap.add_mutually_exclusive_group(required=True)
    where.add_argument("--port", help="serial port, e.g. COM12 or /dev/ttyACM0")
    where.add_argument("--tcp", help="host:port, e.g. 127.0.0.1:5000 (the fake runner)")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--label", required=True, help="radio and firmware, e.g. 'RAK4631 offband-v1.5.0-beta7'")
    ap.add_argument("--out", required=True)
    ap.add_argument("--drain-queue", action="store_true",
                    help="also sync queued messages (REMOVES them from the radio)")
    ap.add_argument("--no-dtr", action="store_true",
                    help="keep DTR low: for ESP32 USB-Serial/JTAG boards (VID 303A)")
    args = ap.parse_args()

    link = TcpLink(args.tcp) if args.tcp else Link(args.port, args.baud, dtr=not args.no_dtr)
    steps = []

    def step(payload, **kw):
        link.send(payload)
        replies, pushes = split(link.frames(**kw))
        steps.append({
            "request": payload.hex(),
            "replies": [r.hex() for r in replies],
            "pushes": [p.hex() for p in pushes],
        })
        return replies

    info = step(bytes([CMD_DEVICE_QUERY, 3]))
    channels = info[0][3] if info and info[0][0] == RESP_DEVICE_INFO and len(info[0]) > 3 else 8
    step(bytes([CMD_APP_START, 0, 0, 0, 0, 0, 0, 0]) + b"offband-trace")
    step(bytes([CMD_GET_DEVICE_TIME]))
    step(bytes([CMD_GET_BATT]))
    step(bytes([CMD_GET_CUSTOM_VARS]))
    step(bytes([CMD_GET_AUTOADD]))
    step(bytes([CMD_GET_CONTACTS]), until=lambda f: f and f[0] == RESP_END_OF_CONTACTS, limit=60.0)
    for index in range(channels):
        step(bytes([CMD_GET_CHANNEL, index]))
    step(bytes([0x7E]))  # an unknown command: firmware's ERR reply
    # Offband extensions; stock firmware answers each with ERR UNSUPPORTED.
    step(bytes([0xC1]))  # GPS status
    step(bytes([0xC2, 0x03]), until=lambda f: len(f) >= 3 and f[0] == 0xC2 and f[2] == 0xFE)  # block LIST
    step(bytes([0xC6, 0x01]))  # packet hash, malformed on purpose: read-only
    if args.drain_queue:
        for _ in range(200):
            replies = step(bytes([CMD_SYNC_NEXT]))
            if not replies or replies[0][0] == RESP_NO_MORE_MESSAGES:
                break

    trace = {
        "format": "offband-radio-trace",
        "format_version": 1,
        "label": args.label,
        "captured": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "port": args.port or f"tcp:{args.tcp}",
        "steps": steps,
    }
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(trace, f, indent=1)
        f.write("\n")
    print(f"{len(steps)} steps, {sum(len(s['replies']) for s in steps)} replies -> {args.out}")


if __name__ == "__main__":
    main()

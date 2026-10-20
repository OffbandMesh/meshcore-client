# Fake radio tools

A software MeshCore companion radio for tests and for using the app with no hardware (Feature #755). The fake itself lives in `test/support/fake_radio/`; it never ships in the app.

## Run it for the desktop app

From the repo root:

```bash
dart run tool/fake_radio.dart --profile offband --port 5000
```

In the app, connect over TCP to this PC's address (`127.0.0.1` on the same machine) and port `5000`.

| Option | Default | Meaning |
|---|---|---|
| `--profile` | `offband` | `offband` (pinned to `offband-v1.5.0-beta7`) or `stock` (MeshCore `companion-v1.17.1`) |
| `--port` | `5000` | TCP port |
| `--seed` | built-in | a seed file (below) or a captured trace |

The radio's clock follows real time, so ACKs and remote-node replies arrive on their own.

Console commands while it runs:

| Command | Does |
|---|---|
| `dm <contact> <text>` | a DM arrives from that contact |
| `chan <index> <text>` | a channel message arrives (MeshCore puts the sender in the text: `Name: hi`) |
| `drop` | drops the link, as a radio losing power would |
| `status` | profile, port, clients, commands received |
| `quit` | stops |

## Seed file

```json
{
  "format": "offband-fake-radio-seed",
  "format_version": 1,
  "name": "Fake Radio",
  "freq_khz": 910525,
  "bw_hz": 62500,
  "sf": 7,
  "cr": 5,
  "tx_power": 20,
  "contacts": [
    { "name": "Alpha", "key": "11" },
    { "name": "Routed", "key": "22", "path": "9a" },
    { "name": "Hilltop", "key": "51", "type": "repeater" }
  ],
  "channels": [
    { "index": 0, "name": "Public" },
    { "index": 1, "name": "#oki", "secret": "5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a" }
  ],
  "remote_nodes": [
    { "contact": "Hilltop", "admin_password": "password", "firmware": "offband" }
  ]
}
```

- `key`: two hex digits (repeated to a 32-byte key) or the full 64-hex key.
- `type`: `chat` (default), `repeater`, `room`, `sensor`.
- `path`: hex route bytes; leave it out for a contact reached by flood.
- `secret`: 16-byte channel secret in hex; zeros if left out.
- `remote_nodes`: contacts that answer login and CLI. `firmware` is `offband` or `stock`; their CLI replies differ where the firmware does (`version`, extra `set radio` parts).

Everything is optional except `format`, `format_version` and each entry's `name` and `key`.

## Capture a real radio

`capture_trace.py` records a radio's replies to the requests a client sends on connect, so the fake can be checked against real firmware:

```bash
pip install pyserial
python tool/fake_radio/capture_trace.py --port COM12 --label "RAK4631 offband-v1.5.0-beta7" --out test/fake_radio/traces/offband-rak4631.json
```

Close the app first: only one program can hold the serial port. The capture is read-only. `--drain-queue` also syncs queued messages, which removes them from the radio. Use `--no-dtr` for ESP32 boards with USB-Serial/JTAG (vendor ID 303A).

A trace works as a seed too: `--seed` with a trace file makes the fake hold what the recorded radio held.

## Protocol manifests

`gen_protocol_manifest.py` reads companion firmware source at a git ref and writes the codes, capability bits and version it defines. The pinned copies in `test/support/fake_radio/manifests/` came from it. OffbandMesh/meshcore-firmware#1318 will publish them from firmware CI instead.

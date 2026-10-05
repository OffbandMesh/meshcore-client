#!/usr/bin/env python3
"""Generate a protocol manifest from MeshCore companion firmware source.

Bootstrap for the fake radio (#769, Feature #755) until
OffbandMesh/meshcore-firmware#1318 publishes manifests from firmware CI.
Reads the source at a git ref (no checkout) and prints JSON to stdout.

  python tool/fake_radio/gen_protocol_manifest.py \
      --repo C:/Dev/meshcore-firmware --ref offband-v1.5.0-beta7 \
      --flavor offband > test/support/fake_radio/manifests/offband-v1.5.0-beta7.json

Stock: --ref companion-v1.17.1 --flavor stock (upstream meshcore-dev/MeshCore
tag, fetched into the clone).
"""
import argparse
import json
import re
import subprocess
import sys

COMPANION = "examples/companion_radio"
DEFINE = re.compile(r"^#define\s+([A-Z0-9_]+)\s+(0x[0-9A-Fa-f]+|\d+)\b", re.M)
CONSTEXPR = re.compile(
    r"^constexpr\s+uint8_t\s+([A-Z0-9_]+)\s*=\s*(0x[0-9A-Fa-f]+|\d+)\s*;", re.M
)
VER_CODE = re.compile(r"^#define\s+FIRMWARE_VER_CODE\s+(\d+)", re.M)
VERSION = re.compile(r'^#define\s+FIRMWARE_VERSION\s+"([^"]+)"', re.M)


def show(repo, ref, path):
    out = subprocess.run(
        ["git", "-C", repo, "show", f"{ref}:{path}"],
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    if out.returncode != 0:
        return None
    return out.stdout


def pick(pairs, prefix):
    return {name: int(value, 0) for name, value in pairs if name.startswith(prefix)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--ref", required=True)
    ap.add_argument("--flavor", choices=["offband", "stock"], required=True)
    args = ap.parse_args()

    header = show(args.repo, args.ref, f"{COMPANION}/MyMesh.h")
    source = show(args.repo, args.ref, f"{COMPANION}/MyMesh.cpp")
    if header is None or source is None:
        sys.exit(f"can't read {COMPANION} at {args.ref}")
    commit = subprocess.run(
        ["git", "-C", args.repo, "rev-parse", f"{args.ref}^{{commit}}"],
        capture_output=True,
        text=True,
    ).stdout.strip()

    defines = DEFINE.findall(source)
    pairs = list(defines)
    offband = show(args.repo, args.ref, f"{COMPANION}/OffbandConfigProtocol.h")
    if args.flavor == "offband":
        if offband is None:
            sys.exit("offband flavor but OffbandConfigProtocol.h is missing")
        pairs += CONSTEXPR.findall(offband) + DEFINE.findall(offband)

    commands = pick(pairs, "CMD_")
    responses = pick(pairs, "RESP_CODE_")
    manifest = {
        "format": "offband-protocol-manifest",
        "format_version": 1,
        "generated_by": "meshcore-client tool/fake_radio/gen_protocol_manifest.py",
        "firmware": {
            "flavor": args.flavor,
            "ref": args.ref,
            "commit": commit,
            "firmware_version": VERSION.search(header).group(1),
            "firmware_ver_code": int(VER_CODE.search(header).group(1)),
        },
        "commands": {k: v for k, v in commands.items() if "OFFBAND" not in k},
        "responses": {k: v for k, v in responses.items() if "OFFBAND" not in k},
        "pushes": pick(pairs, "PUSH_CODE_"),
        "errors": pick(pairs, "ERR_CODE_"),
        "offband_commands": {k: v for k, v in commands.items() if "OFFBAND" in k},
        "offband_responses": {k: v for k, v in responses.items() if "OFFBAND" in k},
        "offband_caps": {
            k: v for k, v in pick(pairs, "OFFBAND_CAP_").items()
        },
        "offband_caps2": pick(pairs, "OFFBAND_CAP2_"),
    }
    print(json.dumps(manifest, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()

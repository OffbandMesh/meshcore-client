"""Pull, decrypt and unpack Send to Offband uploads (#1195).

    python tools/logs/offband_logs.py keygen
    python tools/logs/offband_logs.py list
    python tools/logs/offband_logs.py pull OB-XXXXX

keygen makes the owner's key pair once. The private key goes to
C:\Dev\.keys\offband-log-key (with the owner's other keys; OFFBAND_LOG_KEY
overrides the path) and into Bitwarden; without it no upload can ever be read.
The public key goes into the app.

list shows uploads not pulled yet. pull downloads an upload, decrypts it,
unpacks it into debug_logs/OB-XXXXX/, labels its intake issue `seen` (which
starts the 30-day deletion clock) and comments there. If anything fails before
the files are written, nothing is marked seen.

Needs CLOUDFLARE_API_TOKEN with R2 read, the `gh` CLI signed in with access to
OffbandMesh/log-intake, and Python's `cryptography` package.
"""
import argparse
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import urllib.request
import zipfile
from datetime import datetime, timezone
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

MAGIC = b"OBLG"
VERSION = 1
HEADER_LENGTH = 53
TAG_LENGTH = 16
INFO = b"offband-log-v1"

INTAKE_REPO = "OffbandMesh/log-intake"
BUCKET = "offband-log-intake"
SEEN_LABEL = "seen"
KEY_PATH = Path(os.environ.get("OFFBAND_LOG_KEY", r"C:\Dev\.keys\offband-log-key"))
OUT_ROOT = Path(__file__).resolve().parents[2] / "debug_logs"
CODE = re.compile(r"^OB-[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{5}$")
OBJECT = re.compile(r"`(uploads/(OB-[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{5})-[0-9a-f-]{36}\.bin)`")


class WrongKey(Exception):
    pass


def key_id(public: bytes) -> bytes:
    return hashlib.sha256(public).digest()[:4]


def public_bytes(private: X25519PrivateKey) -> bytes:
    return private.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )


def open_envelope(blob: bytes, private: X25519PrivateKey) -> bytes:
    """The zipped package inside an upload. Raises on anything not sealed to
    this key or altered since: a wrong key id, a bad header, a failed tag."""
    if len(blob) < HEADER_LENGTH + TAG_LENGTH:
        raise ValueError(f"upload is {len(blob)} bytes, too short to be an envelope")
    header = blob[:HEADER_LENGTH]
    if header[:4] != MAGIC or header[4] != VERSION:
        raise ValueError("upload does not start with the OBLG version 1 header")
    recipient = public_bytes(private)
    if header[5:9] != key_id(recipient):
        raise WrongKey(
            f"upload was sealed for key id {header[5:9].hex()}, this key is {key_id(recipient).hex()}"
        )
    ephemeral = header[9:41]
    shared = private.exchange(X25519PublicKey.from_public_bytes(ephemeral))
    key = HKDF(
        algorithm=hashes.SHA256(), length=32, salt=ephemeral + recipient, info=INFO
    ).derive(shared)
    return AESGCM(key).decrypt(header[41:53], blob[HEADER_LENGTH:], header)


def unpack(package: bytes, dest: Path) -> list:
    """Write every member of [package] under [dest]. A member that would land
    outside [dest] is refused before anything is written."""
    root = dest.resolve()
    with zipfile.ZipFile(io.BytesIO(package)) as zf:
        members = [m for m in zf.infolist() if not m.is_dir()]
        for m in members:
            target = (root / m.filename).resolve()
            if root != target and root not in target.parents:
                raise ValueError(f"package member {m.filename!r} points outside {dest}")
        written = []
        for m in members:
            target = root / m.filename
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(zf.read(m))
            written.append(m.filename)
    return written


def free_dir(root: Path, code: str) -> Path:
    candidate = root / code
    n = 2
    while candidate.exists():
        candidate = root / f"{code}-{n}"
        n += 1
    return candidate


def load_key(path: Path = KEY_PATH) -> X25519PrivateKey:
    if not path.exists():
        raise SystemExit(f"No private key at {path}. Restore it from Bitwarden, or run keygen once.")
    return X25519PrivateKey.from_private_bytes(bytes.fromhex(path.read_text().strip()))


def keygen(path: Path = KEY_PATH, out=sys.stdout) -> bytes:
    if path.exists():
        raise SystemExit(f"{path} already exists. Refusing to overwrite the only key that reads past uploads.")
    private = X25519PrivateKey.generate()
    raw = private.private_bytes(
        serialization.Encoding.Raw,
        serialization.PrivateFormat.Raw,
        serialization.NoEncryption(),
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(raw.hex() + "\n")
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
    public = public_bytes(private)
    print(f"Private key written to {path}", file=out)
    print("Store it in Bitwarden now. Without it no upload can ever be read.", file=out)
    print(f"Public key: {public.hex()}", file=out)
    print(f"Key id:     {key_id(public).hex()}", file=out)
    return public


# --- GitHub and Cloudflare --------------------------------------------------


def gh(*args: str) -> str:
    return subprocess.run(
        ["gh", *args], check=True, capture_output=True, text=True, encoding="utf-8"
    ).stdout


def cf_get(path: str) -> bytes:
    token = os.environ.get("CLOUDFLARE_API_TOKEN")
    if not token:
        raise SystemExit("CLOUDFLARE_API_TOKEN is not set.")
    req = urllib.request.Request(
        f"https://api.cloudflare.com/client/v4{path}",
        headers={"Authorization": f"Bearer {token}"},
    )
    with urllib.request.urlopen(req, timeout=120) as res:
        return res.read()


def download(object_key: str) -> bytes:
    accounts = json.loads(cf_get("/accounts"))["result"]
    if len(accounts) != 1:
        raise SystemExit(f"Expected one Cloudflare account, found {len(accounts)}.")
    quoted = urllib.request.quote(object_key, safe="")
    return cf_get(f"/accounts/{accounts[0]['id']}/r2/buckets/{BUCKET}/objects/{quoted}")


def intake_issues(state: str, search: str = "") -> list:
    args = ["issue", "list", "--repo", INTAKE_REPO, "--state", state, "--limit", "200",
            "--json", "number,title,body,labels,createdAt"]
    if search:
        args += ["--search", search]
    return json.loads(gh(*args))


def mark_seen(number: int, note: str) -> None:
    gh("label", "create", SEEN_LABEL, "--repo", INTAKE_REPO, "--force",
       "--description", "Pulled by the owner; deleted 30 days later")
    gh("issue", "edit", str(number), "--repo", INTAKE_REPO, "--add-label", SEEN_LABEL)
    gh("issue", "comment", str(number), "--repo", INTAKE_REPO, "--body", note)


# --- Commands ---------------------------------------------------------------


def unseen(issues: list) -> list:
    return [i for i in issues if SEEN_LABEL not in {label["name"] for label in i["labels"]}]


def pull(code: str, *, key=None, issues=None, fetch=download, seen=mark_seen,
         out_root: Path = OUT_ROOT, out=sys.stdout) -> list:
    if not CODE.match(code):
        raise SystemExit(f"{code!r} is not a reference code like OB-7K2QX.")
    key = key or load_key()
    issues = issues if issues is not None else intake_issues("all", f"{code} in:title")
    targets = []
    for issue in issues:
        if not issue["title"].startswith(code):
            continue
        for object_key, object_code in OBJECT.findall(issue["body"] or ""):
            if object_code == code:
                targets.append((issue["number"], object_key))
    if not targets:
        raise SystemExit(f"No intake issue names a stored upload for {code}.")

    pulled = []
    for number, object_key in targets:
        package = open_envelope(fetch(object_key), key)
        dest = free_dir(out_root, code)
        files = unpack(package, dest)
        when = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
        seen(number, f"Pulled and decrypted {when}: {len(files)} files. Deleted 30 days from now.")
        print(f"#{number}: {len(files)} files in {dest}", file=out)
        pulled.append(dest)
    return pulled


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("keygen", help="make the owner key pair, once")
    sub.add_parser("list", help="uploads not pulled yet")
    p = sub.add_parser("pull", help="download, decrypt and unpack one upload")
    p.add_argument("code")
    args = parser.parse_args(argv)

    if args.command == "keygen":
        keygen()
    elif args.command == "list":
        waiting = unseen(intake_issues("open"))
        for issue in waiting:
            print(f"#{issue['number']}  {issue['createdAt'][:16]}  {issue['title']}")
        print(f"{len(waiting)} upload(s) not pulled yet.")
    else:
        pull(args.code)
    return 0


if __name__ == "__main__":
    sys.exit(main())

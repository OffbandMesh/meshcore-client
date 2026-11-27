r"""Pull, decrypt and unpack Send to Offband uploads (#1195).

    python tools/logs/offband_logs.py keygen
    python tools/logs/offband_logs.py list
    python tools/logs/offband_logs.py pull OB-XXXXX

keygen makes the owner's key pair once. The private key goes to
C:\Dev\.keys\offband-log-key (with the owner's other keys; OFFBAND_LOG_KEY
overrides the path) and into Bitwarden; without it no upload can ever be read.
The public key goes into the app.

list shows uploads not pulled yet. pull downloads an upload, decrypts it and
unpacks it into the main checkout's debug_logs, in a folder named
"YYYY-MM-DD OB-XXXXX <sender's name>" (OFFBAND_LOG_DIR overrides the parent
folder). It is never written inside a worktree, which would lose it when the
worktree is removed. Then it labels the intake issue `seen` (which starts the
30-day deletion clock) and comments there. If anything fails before the files
are written, nothing is marked seen.

Needs CLOUDFLARE_API_TOKEN with R2 read on the offband-log-intake bucket, the
`gh` CLI signed in with access to OffbandMesh/log-intake, and Python's
`cryptography` package (pip install --user cryptography).
"""
import argparse
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import urllib.error
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
SENDER_FILE = "sender.json"
MAX_SENDER_BYTES = 4096
# Anyone holding the public key can upload, so a package is untrusted; this
# refuses a zip bomb before anything is written.
MAX_UNPACKED_BYTES = 1024 * 1024 * 1024
UNSAFE_IN_NAME = re.compile(r'[<>:"/\\|?*\x00-\x1f]')
CODE =re.compile(r"^OB-[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{5}$")
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
        total = sum(m.file_size for m in members)
        if total > MAX_UNPACKED_BYTES:
            raise ValueError(f"package would unpack to {total} bytes, over the {MAX_UNPACKED_BYTES} limit")
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


def default_out_root(start: Path = Path(__file__).resolve().parent) -> Path:
    """debug_logs in the main checkout, found from git, even when this runs
    from a worktree. OFFBAND_LOG_DIR overrides it."""
    override = os.environ.get("OFFBAND_LOG_DIR")
    if override:
        return Path(override)
    try:
        common = subprocess.run(
            ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
            cwd=start, check=True, capture_output=True, text=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as e:
        raise SystemExit(f"Could not find the main checkout from {start} ({e}). Set OFFBAND_LOG_DIR.")
    if not Path(common).is_absolute():
        raise SystemExit(f"git gave a relative path ({common}); git 2.31+ is needed. Set OFFBAND_LOG_DIR.")
    return Path(common).parent / "debug_logs"


def sender_of(package: bytes) -> dict:
    """The optional name and email the sender gave, from sender.json."""
    with zipfile.ZipFile(io.BytesIO(package)) as zf:
        if SENDER_FILE not in zf.namelist() or zf.getinfo(SENDER_FILE).file_size > MAX_SENDER_BYTES:
            return {}
        try:
            data = json.loads(zf.read(SENDER_FILE))
        except ValueError:
            return {}
    return {k: str(data[k]) for k in ("name", "email") if isinstance(data, dict) and data.get(k)}


def folder_name(code: str, uploaded_at: str, name: str = "") -> str:
    """The folder for an upload: local date, code, then the sender's name.
    The name comes from the sender, so anything a folder name cannot hold is
    dropped."""
    day = datetime.fromisoformat(uploaded_at.replace("Z", "+00:00")).astimezone()
    clean = UNSAFE_IN_NAME.sub("", name).strip().rstrip(". ")[:60].strip()
    base = f"{day:%Y-%m-%d} {code}"
    return f"{base} {clean}" if clean else base


def free_dir(root: Path, name: str) -> Path:
    candidate = root / name
    n = 2
    while candidate.exists():
        candidate = root / f"{name}-{n}"
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
    try:
        with urllib.request.urlopen(req, timeout=120) as res:
            return res.read()
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            raise SystemExit(
                f"Cloudflare refused the request (HTTP {e.code}). CLOUDFLARE_API_TOKEN "
                f"needs R2 read on the {BUCKET} bucket, or it has expired."
            )
        raise SystemExit(f"Cloudflare answered HTTP {e.code} for {path}.")


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
         out_root: Path = None, out=sys.stdout) -> list:
    if not CODE.match(code):
        raise SystemExit(f"{code!r} is not a reference code like OB-7K2QX.")
    key = key or load_key()
    out_root = out_root or default_out_root()
    issues = issues if issues is not None else intake_issues("all", f"{code} in:title")
    targets = []
    for issue in issues:
        if not issue["title"].startswith(code):
            continue
        for object_key, object_code in OBJECT.findall(issue["body"] or ""):
            if object_code == code:
                targets.append((issue, object_key))
    if not targets:
        raise SystemExit(f"No intake issue names a stored upload for {code}.")

    pulled = []
    for issue, object_key in targets:
        package = open_envelope(fetch(object_key), key)
        sender = sender_of(package)
        dest = free_dir(out_root, folder_name(code, issue["createdAt"], sender.get("name", "")))
        files = unpack(package, dest)
        when = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
        seen(issue["number"], f"Pulled and decrypted {when}: {len(files)} files. Deleted 30 days from now.")
        print(f"#{issue['number']}: {len(files)} files in {dest}", file=out)
        if sender:
            print(f"  From: {sender.get('name', '(no name)')}  {sender.get('email', '(no email)')}", file=out)
        else:
            print("  No contact details given.", file=out)
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

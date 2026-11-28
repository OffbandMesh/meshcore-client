#!/usr/bin/env python3
"""Send a signed Offband release bundle to a Google Play track (#1053, #1084).

Standard library only. Two commands:

  tracks   Read-only: list every track and its releases. Changes nothing.
  publish  Check the bundle, then put this release on Internal, External
           (closed testing) or production at the rollout asked for. The
           first publish of a release uploads it; later ones promote the same
           bundle to another track.

The access token comes from the PLAY_ACCESS_TOKEN environment variable and is
never printed. Every check that can't tell what is true stops the run (PLAN.md
section 6); nothing is guessed. A failed run deletes its uncommitted edit, so
Play is left as it was.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

PACKAGE = "app.offband.meshcore"

# The same pin as release-signed.yml's two certificate checks. A test keeps
# them identical.
EXPECTED_CERT_SHA256 = (
    "e7da8cd5bf22ac3eda7cb954b8b120a18b6c4382d1b6e6fdd204ddedddaf5488"
)

# Play's API names for the three targets. A3 reads the real names live.
TRACKS = {"internal": "internal", "external": "alpha", "production": "production"}
# Testing tracks go to their whole tester list: no percentage.
WHOLE_LIST = {"internal": "Internal", "external": "External"}
ROLLOUTS = ("draft", "10", "25", "50", "100")
NOTES_MAX = 500
NOTES_LANGUAGE = "en-US"

API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
UPLOAD = (
    "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications"
)


class Stop(Exception):
    """A check failed or couldn't tell. The run ends and changes nothing."""


# --- Bundle reading ----------------------------------------------------------


def _der(data: bytes, pos: int) -> tuple[int, int, int]:
    """Reads one DER header at pos. Returns (tag, content start, content end)."""
    if pos + 2 > len(data):
        raise Stop("signature block is truncated")
    tag = data[pos]
    length = data[pos + 1]
    pos += 2
    if length & 0x80:
        count = length & 0x7F
        if count == 0 or count > 4 or pos + count > len(data):
            raise Stop("signature block has an unreadable length")
        length = int.from_bytes(data[pos : pos + count], "big")
        pos += count
    end = pos + length
    if end > len(data):
        raise Stop("signature block is truncated")
    return tag, pos, end


def _children(data: bytes, start: int, end: int) -> list[tuple[int, int, int, int]]:
    """Each child TLV as (tag, header start, content start, content end)."""
    out = []
    pos = start
    while pos < end:
        tag, body, stop = _der(data, pos)
        out.append((tag, pos, body, stop))
        pos = stop
    return out


def signer_certificate(block: bytes) -> bytes:
    """The first certificate in a PKCS#7 SignedData block, as DER bytes.

    ContentInfo { contentType, [0] SignedData { version, digestAlgorithms,
    encapContentInfo, [0] certificates, ... } }. keytool's SHA-256 is the
    digest of exactly these bytes.
    """
    tag, body, end = _der(block, 0)
    if tag != 0x30:
        raise Stop("signature block is not a PKCS#7 structure")
    info = _children(block, body, end)
    if len(info) < 2 or info[1][0] != 0xA0:
        raise Stop("signature block has no signed content")
    _, _, inner, inner_end = info[1]
    tag, body, end = _der(block, inner)
    if tag != 0x30:
        raise Stop("signature block's signed content is malformed")
    for tag, _, cert_body, cert_end in _children(block, body, end):
        if tag == 0xA0:
            certs = _children(block, cert_body, cert_end)
            if not certs:
                break
            _, head, _, stop = certs[0]
            return block[head:stop]
    raise Stop("signature block carries no certificate")


def certificate_sha256(aab: zipfile.ZipFile) -> str:
    blocks = [
        n
        for n in aab.namelist()
        if re.fullmatch(r"META-INF/[^/]+\.(RSA|EC|DSA)", n, re.IGNORECASE)
    ]
    if len(blocks) != 1:
        raise Stop(f"bundle has {len(blocks)} signature blocks, expected 1")
    cert = signer_certificate(aab.read(blocks[0]))
    return hashlib.sha256(cert).hexdigest()


def _varint(data: bytes, pos: int) -> tuple[int, int]:
    value = shift = 0
    while True:
        if pos >= len(data):
            raise Stop("bundle manifest is truncated")
        byte = data[pos]
        pos += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, pos
        shift += 7
        if shift > 63:
            raise Stop("bundle manifest has an unreadable number")


def _fields(data: bytes) -> list[tuple[int, int, object]]:
    """Protobuf fields as (number, wire type, int or bytes)."""
    out = []
    pos = 0
    while pos < len(data):
        key, pos = _varint(data, pos)
        number, wire = key >> 3, key & 7
        if wire == 0:
            value, pos = _varint(data, pos)
        elif wire == 2:
            size, pos = _varint(data, pos)
            if pos + size > len(data):
                raise Stop("bundle manifest is truncated")
            value, pos = data[pos : pos + size], pos + size
        elif wire == 5:
            value, pos = data[pos : pos + 4], pos + 4
        elif wire == 1:
            value, pos = data[pos : pos + 8], pos + 8
        else:
            raise Stop("bundle manifest has an unreadable field")
        out.append((number, wire, value))
    return out


def manifest_version_code(manifest: bytes) -> int:
    """android:versionCode from a bundle's protobuf AndroidManifest.xml.

    aapt2's XmlNode: element = 1. XmlElement: name = 3, attribute = 4.
    XmlAttribute: name = 2, value = 3, compiled_item = 6. Item: prim = 7.
    Primitive: int_decimal_value = 6.
    """
    element = next((v for n, w, v in _fields(manifest) if n == 1 and w == 2), None)
    if element is None:
        raise Stop("bundle manifest has no root element")
    fields = _fields(element)
    name = next((v for n, w, v in fields if n == 3 and w == 2), b"")
    if name != b"manifest":
        raise Stop("bundle manifest's root is not <manifest>")
    for n, w, attribute in fields:
        if n != 4 or w != 2:
            continue
        parts = _fields(attribute)
        if next((v for n, w, v in parts if n == 2 and w == 2), b"") != b"versionCode":
            continue
        for n, w, item in parts:
            if n == 6 and w == 2:
                for n2, w2, prim in _fields(item):
                    if n2 == 7 and w2 == 2:
                        for n3, w3, value in _fields(prim):
                            if n3 == 6 and w3 == 0:
                                return value
        text = next((v for n, w, v in parts if n == 3 and w == 2), b"")
        if text.isdigit():
            return int(text)
        raise Stop("bundle manifest's versionCode is unreadable")
    raise Stop("bundle manifest has no versionCode")


def read_bundle(path: Path) -> dict:
    if not path.is_file():
        raise Stop(f"no bundle at {path}")
    try:
        with zipfile.ZipFile(path) as aab:
            cert = certificate_sha256(aab)
            try:
                manifest = aab.read("base/manifest/AndroidManifest.xml")
            except KeyError:
                raise Stop("bundle has no base/manifest/AndroidManifest.xml")
            code = manifest_version_code(manifest)
    except zipfile.BadZipFile:
        raise Stop(f"{path} is not a bundle")
    return {
        "cert_sha256": cert,
        "version_code": code,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }


# --- Release facts from the tag ----------------------------------------------


def pubspec_version(pubspec: Path) -> tuple[str, int]:
    match = re.search(
        r"^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$", pubspec.read_text("utf-8"), re.M
    )
    if not match:
        raise Stop(f"{pubspec} has no version of the form X.Y.Z+N")
    return match.group(1), int(match.group(2))


def check_tag(tag: str, version: str) -> None:
    if tag != f"v{version}" and not tag.startswith(f"v{version}-"):
        raise Stop(f"tag {tag} is not a release of pubspec version {version}")


def read_notes(notes_dir: Path, version: str) -> str:
    path = notes_dir / f"{version}.txt"
    if not path.is_file():
        raise Stop(f"release notes {path} are missing")
    text = path.read_text("utf-8").strip()
    if not text:
        raise Stop(f"release notes {path} are empty")
    if len(text) > NOTES_MAX:
        raise Stop(f"release notes {path} are {len(text)} characters, over {NOTES_MAX}")
    return text


def check_bundle(bundle: dict, version_code: int) -> None:
    if bundle["cert_sha256"] != EXPECTED_CERT_SHA256:
        raise Stop(
            f"bundle certificate {bundle['cert_sha256']} is not the release key"
        )
    if bundle["version_code"] != version_code:
        raise Stop(
            f"bundle version code {bundle['version_code']} differs from the "
            f"tag's pubspec, {version_code}"
        )


# --- Track rules --------------------------------------------------------------


def wanted_release(rollout: str, target: str) -> dict:
    if rollout not in ROLLOUTS:
        raise Stop(f"rollout {rollout} is not one of {', '.join(ROLLOUTS)}")
    if target in WHOLE_LIST and rollout not in ("draft", "100"):
        raise Stop(f"{WHOLE_LIST[target]} goes to its whole tester list: use draft or 100")
    if rollout == "draft":
        return {"status": "draft"}
    if rollout == "100":
        return {"status": "completed"}
    return {"status": "inProgress", "userFraction": int(rollout) / 100}


def reach(release: dict) -> float:
    """How widely a release is served: draft 0, a fraction, completed 1."""
    status = release.get("status")
    if status == "draft":
        return 0.0
    if status == "completed":
        return 1.0
    if status == "inProgress":
        return float(release.get("userFraction", 0))
    raise Stop(f"release status {status} can't be compared; change it in Console")


def plan_track(track: dict, version_code: int, wanted: dict) -> list | None:
    """The track's new release list, or None when it already serves this.

    A completed release replaces the track's current completed release, as
    Play Console does on a full rollout: Play allows one completed release per
    track (#1250). The replaced version stays in the bundle library. Any other
    release is kept. Stops when a different version is mid rollout, or when
    the request would narrow what the track already serves.
    """
    code = str(version_code)
    releases = track.get("releases", [])
    ours = [r for r in releases if code in r.get("versionCodes", [])]
    others = [r for r in releases if code not in r.get("versionCodes", [])]
    for release in others:
        if release.get("status") in ("inProgress", "halted"):
            raise Stop(
                f"version {', '.join(release.get('versionCodes', []))} is mid "
                f"rollout on {track.get('track')}: finish or halt it in Console"
            )
    if ours:
        if len(ours) > 1:
            raise Stop(f"{track.get('track')} lists version {code} twice")
        if ours[0].get("versionCodes") != [code]:
            raise Stop(
                f"{track.get('track')} serves version {code} in one release with "
                f"{', '.join(ours[0].get('versionCodes', []))}: change it in Console"
            )
        current, asked = reach(ours[0]), reach(wanted)
        if current == asked and ours[0].get("status") == wanted["status"]:
            return None
        if current > asked:
            raise Stop(
                f"{track.get('track')} already serves version {code} wider than "
                "asked: narrowing or halting is done in Console"
            )
    if wanted["status"] == "completed":
        others = [r for r in others if r.get("status") != "completed"]
    return others + [wanted]


# --- Play API -----------------------------------------------------------------


class Play:
    """Android Publisher edits, over urllib. Tests replace `send`."""

    def __init__(self, token: str, package: str = PACKAGE):
        self.token = token
        self.package = package

    def send(self, method, url, body=None, content_type="application/json"):
        request = urllib.request.Request(url, data=body, method=method)
        request.add_header("Authorization", f"Bearer {self.token}")
        if body is not None:
            request.add_header("Content-Type", content_type)
        try:
            with urllib.request.urlopen(request, timeout=600) as response:
                raw = response.read()
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", "replace")
            try:
                detail = json.loads(detail)["error"]["message"]
            except (ValueError, KeyError, TypeError):
                pass
            raise Stop(f"Play refused {method} ({error.code}): {detail}")
        except urllib.error.URLError as error:
            raise Stop(f"Play unreachable: {error.reason}")
        return json.loads(raw) if raw else {}

    def _edit(self, edit_id: str = "") -> str:
        base = f"{API}/{self.package}/edits"
        return f"{base}/{edit_id}" if edit_id else base

    def open_edit(self) -> str:
        return self.send("POST", self._edit(), b"{}")["id"]

    def delete_edit(self, edit_id: str) -> None:
        self.send("DELETE", self._edit(edit_id))

    def tracks(self, edit_id: str) -> list:
        return self.send("GET", f"{self._edit(edit_id)}/tracks").get("tracks", [])

    def bundles(self, edit_id: str) -> list:
        return self.send("GET", f"{self._edit(edit_id)}/bundles").get("bundles", [])

    def upload(self, edit_id: str, aab: Path) -> dict:
        url = f"{UPLOAD}/{self.package}/edits/{edit_id}/bundles?uploadType=media"
        return self.send("POST", url, aab.read_bytes(), "application/octet-stream")

    def set_track(self, edit_id: str, track: str, releases: list) -> None:
        body = json.dumps({"track": track, "releases": releases}).encode()
        self.send("PUT", f"{self._edit(edit_id)}/tracks/{track}", body)

    def commit(self, edit_id: str) -> None:
        self.send("POST", f"{self._edit(edit_id)}:commit")


def highest_code(tracks: list, bundles: list) -> int:
    codes = [int(b["versionCode"]) for b in bundles if "versionCode" in b]
    for track in tracks:
        for release in track.get("releases", []):
            codes += [int(c) for c in release.get("versionCodes", [])]
    return max(codes, default=0)


def list_tracks(play: Play, out=print) -> None:
    edit = play.open_edit()
    try:
        for track in play.tracks(edit):
            out(f"track {track.get('track')}")
            for release in track.get("releases", []):
                fraction = release.get("userFraction")
                extra = f" at {fraction:.0%}" if fraction is not None else ""
                codes = ", ".join(release.get("versionCodes", [])) or "none"
                out(
                    f"  {release.get('name', '(unnamed)')}: versions {codes}, "
                    f"{release.get('status')}{extra}"
                )
    finally:
        play.delete_edit(edit)


def publish(play: Play, aab: Path, pubspec: Path, notes_dir: Path, tag: str,
            target: str, rollout: str, out=print) -> str:
    if target not in TRACKS:
        raise Stop(f"target {target} is not internal, external or production")
    wanted = wanted_release(rollout, target)
    version, version_code = pubspec_version(pubspec)
    check_tag(tag, version)
    notes = read_notes(notes_dir, version)
    bundle = read_bundle(aab)
    check_bundle(bundle, version_code)
    wanted.update(
        name=f"{version_code} ({version})",
        versionCodes=[str(version_code)],
        releaseNotes=[{"language": NOTES_LANGUAGE, "text": notes}],
    )
    track_name = TRACKS[target]

    edit = play.open_edit()
    committed = False
    try:
        tracks = play.tracks(edit)
        bundles = play.bundles(edit)
        held = [b for b in bundles if str(b.get("versionCode")) == str(version_code)]
        if held and held[0].get("sha256", "").lower() != bundle["sha256"]:
            raise Stop(
                f"Play already holds a different bundle as version {version_code}"
            )
        if not held and version_code <= highest_code(tracks, bundles):
            raise Stop(
                f"version {version_code} is not higher than Play's highest, "
                f"{highest_code(tracks, bundles)}"
            )
        current = next((t for t in tracks if t.get("track") == track_name), None)
        if current is None:
            raise Stop(f"Play has no track named {track_name}")
        releases = plan_track(current, version_code, wanted)
        if releases is None:
            out(f"{track_name} already serves {wanted['name']} as asked; nothing changed")
            return "unchanged"
        if held:
            out(f"Play already holds version {version_code}; not uploading again")
        else:
            uploaded = play.upload(edit, aab)
            if str(uploaded.get("versionCode")) != str(version_code):
                raise Stop(
                    f"Play read the upload as version {uploaded.get('versionCode')}"
                )
            out(f"uploaded version {version_code}")
        play.set_track(edit, track_name, releases)
        play.commit(edit)
        committed = True
        out(f"{wanted['name']} is on {track_name}: {rollout}")
        return "published"
    finally:
        if not committed:
            try:
                play.delete_edit(edit)
            except Stop:
                pass


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("tracks", help="list Play's tracks, read-only")
    send = commands.add_parser("publish", help="put this release on a track")
    send.add_argument("--aab", type=Path, required=True)
    send.add_argument("--tag", required=True)
    send.add_argument("--target", choices=sorted(TRACKS), required=True)
    send.add_argument("--rollout", choices=ROLLOUTS, required=True)
    send.add_argument("--pubspec", type=Path, default=Path("pubspec.yaml"))
    send.add_argument("--notes-dir", type=Path, default=Path("play"))
    args = parser.parse_args(argv)

    token = os.environ.get("PLAY_ACCESS_TOKEN", "")
    if not token:
        print("stop: PLAY_ACCESS_TOKEN is not set", file=sys.stderr)
        return 1
    play = Play(token)
    try:
        if args.command == "tracks":
            list_tracks(play)
        else:
            publish(play, args.aab, args.pubspec, args.notes_dir, args.tag,
                    args.target, args.rollout)
    except Stop as stop:
        print(f"stop: {stop}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

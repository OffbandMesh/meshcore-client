"""Tests for play_release.py (#1084). Run: python -m unittest discover -s tools/play

Each refusal in PLAN.md section 6 that the tool owns has a test here. The
workflow-level rows (identity condition, tag on main, release asset present,
provenance) belong to play-publish.yml and are tested there (#1087, #1088).
"""

from __future__ import annotations

import copy
import hashlib
import io
import re
import tempfile
import unittest
import zipfile
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

import play_release as p

REPO = Path(__file__).resolve().parents[2]


# --- Fixture builders ---------------------------------------------------------


def der(tag: int, body: bytes) -> bytes:
    n = len(body)
    if n < 0x80:
        return bytes([tag, n]) + body
    size = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([tag, 0x80 | len(size)]) + size + body


def pkcs7(cert: bytes) -> bytes:
    signed = der(
        0x30,
        der(0x02, b"\x01")
        + der(0x31, b"")
        + der(0x30, der(0x06, b"\x2a\x86\x48\x86\xf7\x0d\x01\x07\x01"))
        + der(0xA0, cert)
        + der(0x31, b""),
    )
    return der(0x30, der(0x06, b"\x2a\x86\x48\x86\xf7\x0d\x01\x07\x02") + der(0xA0, signed))


def fake_cert(seed: bytes) -> bytes:
    return der(0x30, der(0x30, der(0x04, seed * 40)) + der(0x30, b""))


def varint(n: int) -> bytes:
    out = bytearray()
    while True:
        byte = n & 0x7F
        n >>= 7
        out.append(byte | (0x80 if n else 0))
        if not n:
            return bytes(out)


def field(number: int, value) -> bytes:
    if isinstance(value, int):
        return varint(number << 3) + varint(value)
    return varint(number << 3 | 2) + varint(len(value)) + value


def manifest(code: int | None, compiled: bool = True) -> bytes:
    attrs = field(4, field(2, b"package") + field(3, b"app.offband.meshcore"))
    if code is not None:
        attr = field(1, b"http://schemas.android.com/apk/res/android")
        attr += field(2, b"versionCode") + field(3, str(code).encode())
        if compiled:
            attr += field(6, field(7, field(6, code)))
        attrs += field(4, attr)
    return field(1, field(3, b"manifest") + attrs)


CERT = fake_cert(b"release")
DEBUG_CERT = fake_cert(b"debug")
PIN = hashlib.sha256(CERT).hexdigest()


def write_aab(path: Path, code: int = 69, cert: bytes = CERT) -> Path:
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("base/manifest/AndroidManifest.xml", manifest(code))
        z.writestr("META-INF/MESHCORE.RSA", pkcs7(cert))
        z.writestr("base/dex/classes.dex", b"dex")
    return path


# --- Fake Play ----------------------------------------------------------------


class FakePlay(p.Play):
    """An in-memory Play: edits stage changes, commit applies them."""

    def __init__(self, tracks=None, bundles=None):
        super().__init__("token")
        self.live_tracks = tracks if tracks is not None else [
            {"track": "alpha", "releases": []},
            {"track": "production", "releases": [
                {"name": "68 (1.7.0)", "versionCodes": ["68"], "status": "completed"}
            ]},
        ]
        self.live_bundles = bundles if bundles is not None else [
            {"versionCode": 68, "sha256": "aa" * 32}
        ]
        self.calls = []
        self.edits = {}
        self.fail = {}
        self.upload_code = None

    def _maybe_fail(self, what):
        if what in self.fail:
            raise p.Stop(self.fail[what])

    def open_edit(self):
        self.calls.append("open")
        edit = f"e{len(self.edits) + 1}"
        self.edits[edit] = {
            "tracks": copy.deepcopy(self.live_tracks),
            "bundles": copy.deepcopy(self.live_bundles),
            "state": "open",
        }
        return edit

    def delete_edit(self, edit):
        self.calls.append("delete")
        self.edits[edit]["state"] = "deleted"

    def tracks(self, edit):
        self.calls.append("tracks")
        self._maybe_fail("tracks")
        return copy.deepcopy(self.edits[edit]["tracks"])

    def bundles(self, edit):
        self.calls.append("bundles")
        return copy.deepcopy(self.edits[edit]["bundles"])

    def upload(self, edit, aab):
        self.calls.append("upload")
        bundle = p.read_bundle(aab)
        code = self.upload_code or bundle["version_code"]
        self.edits[edit]["bundles"].append({"versionCode": code, "sha256": bundle["sha256"]})
        return {"versionCode": code, "sha256": bundle["sha256"]}

    def set_track(self, edit, track, releases):
        self.calls.append(f"set {track}")
        for t in self.edits[edit]["tracks"]:
            if t["track"] == track:
                t["releases"] = copy.deepcopy(releases)

    def commit(self, edit):
        self.calls.append("commit")
        self._maybe_fail("commit")
        self.live_tracks = self.edits[edit]["tracks"]
        self.live_bundles = self.edits[edit]["bundles"]
        self.edits[edit]["state"] = "committed"

    def track(self, name):
        return next(t for t in self.live_tracks if t["track"] == name)


# --- Tests --------------------------------------------------------------------


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.pin = mock.patch.object(p, "EXPECTED_CERT_SHA256", PIN)
        self.pin.start()
        self.addCleanup(self.pin.stop)
        self.pubspec = self.dir / "pubspec.yaml"
        self.pubspec.write_text("name: x\nversion: 1.8.0+69\n", "utf-8")
        self.notes = self.dir / "play"
        self.notes.mkdir()
        (self.notes / "1.8.0.txt").write_text("Fixes and improvements.\n", "utf-8")
        self.aab = write_aab(self.dir / "app-release.aab")
        self.play = FakePlay()

    def run_publish(self, target="external", rollout="draft", tag="v1.8.0"):
        return p.publish(self.play, self.aab, self.pubspec, self.notes, tag,
                         target, rollout, out=lambda *_: None)

    def assertStops(self, pattern, **kwargs):
        with self.assertRaisesRegex(p.Stop, pattern):
            self.run_publish(**kwargs)

    def assertNothingCommitted(self):
        self.assertNotIn("commit", self.play.calls)
        for edit in self.play.edits.values():
            self.assertEqual(edit["state"], "deleted")


class BundleReading(Base):
    def test_reads_version_code_and_certificate(self):
        bundle = p.read_bundle(self.aab)
        self.assertEqual(bundle["version_code"], 69)
        self.assertEqual(bundle["cert_sha256"], PIN)

    def test_reads_an_uncompiled_version_code(self):
        self.assertEqual(p.manifest_version_code(manifest(70, compiled=False)), 70)

    def test_no_version_code_stops(self):
        with self.assertRaisesRegex(p.Stop, "no versionCode"):
            p.manifest_version_code(manifest(None))

    def test_long_certificate_lengths_parse(self):
        big = fake_cert(b"x" * 50)
        self.assertEqual(p.signer_certificate(pkcs7(big)), big)

    def test_pin_matches_release_signed_workflow(self):
        workflow = (REPO / ".github/workflows/release-signed.yml").read_text("utf-8")
        pins = re.findall(r"EXPECTED_SHA256:\s*([0-9a-f]{64})", workflow)
        self.assertEqual(len(pins), 2)
        self.pin.stop()
        try:
            self.assertEqual(set(pins), {p.EXPECTED_CERT_SHA256})
        finally:
            self.pin.start()


class Refusals(Base):
    """PLAN.md section 6, the rows the tool owns."""

    def test_missing_token_stops(self):
        with mock.patch.dict("os.environ", {}, clear=True), redirect_stderr(io.StringIO()) as err:
            self.assertEqual(p.main(["tracks"]), 1)
        self.assertIn("PLAY_ACCESS_TOKEN", err.getvalue())

    def test_missing_bundle_stops(self):
        self.aab.unlink()
        self.assertStops("no bundle")
        self.assertEqual(self.play.calls, [])

    def test_debug_or_other_certificate_stops(self):
        write_aab(self.aab, cert=DEBUG_CERT)
        self.assertStops("not the release key")
        self.assertEqual(self.play.calls, [])

    def test_version_code_differs_from_pubspec_stops(self):
        write_aab(self.aab, code=70)
        self.assertStops("differs from the tag's pubspec")
        self.assertEqual(self.play.calls, [])

    def test_tag_not_of_this_version_stops(self):
        self.assertStops("not a release of pubspec version", tag="v1.7.9")

    def test_rc_tag_of_this_version_is_accepted(self):
        self.assertEqual(self.run_publish(tag="v1.8.0-rc.1"), "published")

    def test_tracks_unreadable_stops(self):
        self.play.fail["tracks"] = "Play refused GET (500): backend"
        self.assertStops("backend")
        self.assertNothingCommitted()

    def test_code_not_higher_than_play_stops(self):
        self.play.live_bundles.append({"versionCode": 69, "sha256": "bb" * 32})
        self.assertStops("different bundle")
        self.play = FakePlay(bundles=[{"versionCode": 70, "sha256": "cc" * 32}])
        self.assertStops("not higher than Play's highest, 70")
        self.assertNothingCommitted()

    def test_code_on_a_track_counts_toward_highest(self):
        self.play.track("alpha")["releases"] = [
            {"versionCodes": ["75"], "status": "completed"}
        ]
        self.assertStops("not higher than Play's highest, 75")

    def test_notes_missing_empty_or_long_stop(self):
        path = self.notes / "1.8.0.txt"
        path.write_text("   \n", "utf-8")
        self.assertStops("are empty")
        path.write_text("x" * 501, "utf-8")
        self.assertStops("501 characters, over 500")
        path.unlink()
        self.assertStops("are missing")
        self.assertEqual(self.play.calls, [])

    def test_notes_at_the_limit_pass(self):
        (self.notes / "1.8.0.txt").write_text("x" * 500 + "\n", "utf-8")
        self.assertEqual(self.run_publish(), "published")

    def test_external_with_a_percentage_stops(self):
        for rollout in ("10", "25", "50"):
            self.assertStops("whole tester list", rollout=rollout)
        self.assertEqual(self.play.calls, [])

    def test_narrowing_stops(self):
        self.run_publish(target="production", rollout="50")
        self.assertStops("narrowing or halting is done in Console",
                         target="production", rollout="25")
        self.assertStops("narrowing", target="production", rollout="draft")

    def test_other_version_mid_rollout_stops(self):
        for status in ("inProgress", "halted"):
            self.play = FakePlay()
            self.play.track("production")["releases"].append(
                {"versionCodes": ["67"], "status": status, "userFraction": 0.2}
            )
            self.assertStops("67 is mid rollout", target="production", rollout="10")
            self.assertNothingCommitted()

    def test_release_shared_with_another_version_stops(self):
        self.play.track("production")["releases"].append(
            {"versionCodes": ["67", "69"], "status": "draft"}
        )
        self.play.live_bundles.append({"versionCode": 69, "sha256": p.read_bundle(self.aab)["sha256"]})
        self.assertStops("in one release with 67, 69", target="production", rollout="100")
        self.assertNothingCommitted()

    def test_unknown_status_of_this_release_stops(self):
        self.play.track("alpha")["releases"] = [
            {"versionCodes": ["69"], "status": "statusUnspecified"}
        ]
        self.play.live_bundles.append({"versionCode": 69, "sha256": p.read_bundle(self.aab)["sha256"]})
        self.assertStops("can't be compared")
        self.assertNothingCommitted()

    def test_review_refusal_stops_without_retry(self):
        self.play.fail["commit"] = (
            "Play refused POST (400): Changes cannot be sent for review automatically"
        )
        self.assertStops("cannot be sent for review")
        self.assertEqual(self.play.calls.count("commit"), 1)
        self.assertEqual(self.play.edits["e1"]["state"], "deleted")
        self.assertEqual(self.play.track("alpha")["releases"], [])

    def test_upload_read_as_another_version_stops(self):
        self.play.upload_code = 71
        self.assertStops("read the upload as version 71")
        self.assertNothingCommitted()

    def test_missing_track_stops(self):
        self.play = FakePlay(tracks=[{"track": "production", "releases": []}])
        self.assertStops("no track named alpha")


class Publishing(Base):
    def test_external_draft_uploads_and_commits(self):
        self.assertEqual(self.run_publish(), "published")
        self.assertEqual(self.play.calls.count("upload"), 1)
        [release] = self.play.track("alpha")["releases"]
        self.assertEqual(release["status"], "draft")
        self.assertEqual(release["versionCodes"], ["69"])
        self.assertEqual(release["name"], "69 (1.8.0)")
        self.assertEqual(release["releaseNotes"],
                         [{"language": "en-US", "text": "Fixes and improvements."}])

    def test_external_100_is_completed(self):
        self.run_publish(rollout="100")
        self.assertEqual(self.play.track("alpha")["releases"][0]["status"], "completed")

    def test_production_staged_keeps_the_serving_release(self):
        self.run_publish(target="production", rollout="10")
        releases = self.play.track("production")["releases"]
        self.assertEqual([r["versionCodes"] for r in releases], [["68"], ["69"]])
        self.assertEqual(releases[1]["status"], "inProgress")
        self.assertEqual(releases[1]["userFraction"], 0.1)

    def test_promote_reuses_the_bundle(self):
        self.run_publish(target="external", rollout="100")
        self.run_publish(target="production", rollout="25")
        self.assertEqual(self.play.calls.count("upload"), 1)
        self.assertEqual(self.play.track("production")["releases"][1]["userFraction"], 0.25)
        self.assertEqual(self.play.track("alpha")["releases"][0]["versionCodes"], ["69"])

    def test_widening_a_rollout(self):
        self.run_publish(target="production", rollout="10")
        self.run_publish(target="production", rollout="100")
        releases = self.play.track("production")["releases"]
        self.assertEqual(releases[-1]["status"], "completed")
        self.assertEqual(len([r for r in releases if "69" in r["versionCodes"]]), 1)

    def test_rerun_at_the_same_rollout_changes_nothing(self):
        self.run_publish(target="production", rollout="25")
        before = copy.deepcopy(self.play.live_tracks)
        calls = len(self.play.calls)
        self.assertEqual(self.run_publish(target="production", rollout="25"), "unchanged")
        new = self.play.calls[calls:]
        self.assertNotIn("upload", new)
        self.assertNotIn("commit", new)
        self.assertEqual(new[-1], "delete")
        self.assertEqual(self.play.live_tracks, before)

    def test_another_draft_on_the_track_is_kept(self):
        self.play.track("alpha")["releases"] = [
            {"versionCodes": ["60"], "status": "draft"}
        ]
        self.run_publish(rollout="100")
        codes = [r["versionCodes"] for r in self.play.track("alpha")["releases"]]
        self.assertEqual(codes, [["60"], ["69"]])


class TrackListing(Base):
    def test_lists_and_changes_nothing(self):
        lines = []
        self.play.track("production")["releases"].append(
            {"name": "69 (1.8.0)", "versionCodes": ["69"], "status": "inProgress",
             "userFraction": 0.1}
        )
        p.list_tracks(self.play, out=lines.append)
        self.assertEqual(self.play.calls, ["open", "tracks", "delete"])
        self.assertIn("track production", lines)
        self.assertIn("  69 (1.8.0): versions 69, inProgress at 10%", lines)


if __name__ == "__main__":
    unittest.main()

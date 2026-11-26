import io
import json
import zipfile
from pathlib import Path

import pytest
from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

import offband_logs as ol

VECTORS = json.loads(
    (Path(__file__).resolve().parents[2] / "test" / "fixtures" / "log_envelope_vectors.json").read_text()
)["vectors"]


def key_of(vector):
    return X25519PrivateKey.from_private_bytes(bytes.fromhex(vector["recipientPrivate"]))


def zipped(files):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        for name, data in files.items():
            zf.writestr(name, data)
    return buf.getvalue()


def test_opens_every_envelope_the_dart_app_makes():
    assert len(VECTORS) == 3
    for v in VECTORS:
        assert ol.open_envelope(bytes.fromhex(v["envelope"]), key_of(v)) == bytes.fromhex(v["plaintext"])


def test_refuses_an_altered_upload():
    v = VECTORS[0]
    blob = bytearray(bytes.fromhex(v["envelope"]))
    blob[-1] ^= 1
    with pytest.raises(InvalidTag):
        ol.open_envelope(bytes(blob), key_of(v))
    header = bytearray(bytes.fromhex(v["envelope"]))
    header[45] ^= 1
    with pytest.raises(InvalidTag):
        ol.open_envelope(bytes(header), key_of(v))


def test_names_the_key_an_upload_was_sealed_for():
    with pytest.raises(ol.WrongKey, match="key id"):
        ol.open_envelope(bytes.fromhex(VECTORS[0]["envelope"]), key_of(VECTORS[1]))


@pytest.mark.parametrize("blob", [b"", b"PK\x03\x04" + bytes(80), b"OBLG\x02" + bytes(80)])
def test_refuses_what_is_not_an_envelope(blob):
    with pytest.raises(ValueError):
        ol.open_envelope(blob, key_of(VECTORS[0]))


def test_unpack_refuses_a_member_outside_the_folder(tmp_path):
    with pytest.raises(ValueError, match="outside"):
        ol.unpack(zipped({"ok.log": b"1", "../escape.txt": b"2"}), tmp_path / "OB-AAAAA")
    assert not (tmp_path / "escape.txt").exists()
    assert not (tmp_path / "OB-AAAAA" / "ok.log").exists()


def test_keygen_writes_once_and_never_overwrites(tmp_path):
    path = tmp_path / ".secrets" / "offband-log-key"
    out = io.StringIO()
    public = ol.keygen(path, out=out)
    assert ol.public_bytes(ol.load_key(path)) == public
    assert public.hex() in out.getvalue()
    assert "Bitwarden" in out.getvalue()
    before = path.read_text()
    with pytest.raises(SystemExit, match="Refusing"):
        ol.keygen(path, out=io.StringIO())
    assert path.read_text() == before


def sealed_package(tmp_path):
    """A real envelope around a real zip, sealed with the Python reference."""
    import make_envelope_vectors as ref

    owner = X25519PrivateKey.generate()
    package = zipped({"manifest.json": b"{}", "offband.log": b"line\n", "traces/anr-1.txt": b"t"})
    blob = ref.seal(package, ol.public_bytes(owner), X25519PrivateKey.generate(), bytes(12))
    return owner, blob


ISSUE = {
    "number": 7,
    "title": "OB-7K2QX: android 1.8.0",
    "body": "Stored as `uploads/OB-7K2QX-1b4e28ba-2fa1-11d2-883f-0016d3cca427.bin`",
    "labels": [],
}


def test_pull_unpacks_and_then_marks_seen(tmp_path):
    owner, blob = sealed_package(tmp_path)
    fetched, marked = [], []
    dests = ol.pull(
        "OB-7K2QX",
        key=owner,
        issues=[ISSUE, {**ISSUE, "number": 8, "title": "OB-99999: other"}],
        fetch=lambda k: fetched.append(k) or blob,
        seen=lambda n, note: marked.append((n, note)),
        out_root=tmp_path,
        out=io.StringIO(),
    )
    assert fetched == ["uploads/OB-7K2QX-1b4e28ba-2fa1-11d2-883f-0016d3cca427.bin"]
    assert dests == [tmp_path / "OB-7K2QX"]
    assert (tmp_path / "OB-7K2QX" / "traces" / "anr-1.txt").read_bytes() == b"t"
    assert [n for n, _ in marked] == [7]
    assert "30 days" in marked[0][1]


def test_a_failed_decrypt_marks_nothing_and_writes_nothing(tmp_path):
    _, blob = sealed_package(tmp_path)
    marked = []
    with pytest.raises(ol.WrongKey):
        ol.pull(
            "OB-7K2QX",
            key=X25519PrivateKey.generate(),
            issues=[ISSUE],
            fetch=lambda k: blob,
            seen=lambda n, note: marked.append(n),
            out_root=tmp_path,
            out=io.StringIO(),
        )
    assert marked == []
    assert list(tmp_path.iterdir()) == []


def test_a_second_pull_does_not_overwrite_the_first(tmp_path):
    owner, blob = sealed_package(tmp_path)
    kwargs = dict(key=owner, issues=[ISSUE], fetch=lambda k: blob,
                  seen=lambda n, note: None, out_root=tmp_path, out=io.StringIO())
    ol.pull("OB-7K2QX", **kwargs)
    assert ol.pull("OB-7K2QX", **kwargs) == [tmp_path / "OB-7K2QX-2"]


def test_list_leaves_out_uploads_already_seen():
    issues = [ISSUE, {**ISSUE, "number": 9, "labels": [{"name": "seen"}]}]
    assert [i["number"] for i in ol.unseen(issues)] == [7]


@pytest.mark.parametrize("code", ["OB-0O1IL", "ob-7k2qx", "OB-7K2Q", "7K2QX"])
def test_refuses_a_malformed_code(code):
    with pytest.raises(SystemExit):
        ol.pull(code, key=X25519PrivateKey.generate(), issues=[])

"""Tests for safe_upload.safe_upload_path().

Covers the security contract for the six /api/* multipart upload routes
in app.py: client-supplied filenames must be sanitised before they hit
disk, and each request must land in its own isolated directory under
/tmp.

Run from repo root:

    pip install pytest werkzeug
    pytest tests/

Or run directly:

    python tests/test_safe_upload.py
"""
from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

# Make safe_upload.py importable when running as `pytest tests/`.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from safe_upload import safe_upload_path  # noqa: E402


class _FakeUploadedFile:
    """Minimal stand-in for werkzeug's FileStorage.

    Has the two attributes safe_upload_path uses: .filename and .save().
    """

    def __init__(self, filename: str, content: bytes = b"x"):
        self.filename = filename
        self._content = content

    def save(self, path: str) -> None:
        with open(path, "wb") as fh:
            fh.write(self._content)


# ---------------------------------------------------------------------------
# Sanitisation -- the security contract
# ---------------------------------------------------------------------------

def test_path_traversal_payload_is_neutralised(tmp_path, monkeypatch):
    """Client-supplied "../../etc/passwd" must NOT escape the upload root."""
    monkeypatch.setattr(tempfile, "mkdtemp", lambda **kw: str(tmp_path))

    f = _FakeUploadedFile("../../etc/passwd", b"poisoned")
    saved = safe_upload_path(f)

    assert saved.startswith(str(tmp_path)), f"escaped: {saved!r}"
    saved_basename = os.path.basename(saved)
    assert "/" not in saved_basename and "\\" not in saved_basename
    assert os.path.isfile(saved)
    with open(saved, "rb") as fh:
        assert fh.read() == b"poisoned"


def test_absolute_path_payload_is_neutralised(tmp_path, monkeypatch):
    """An absolute filename "/etc/cron.d/x" must NOT be honoured.

    Pre-fix, os.path.join("/tmp", "/etc/cron.d/x") returned
    "/etc/cron.d/x" because Python absorbs absolute right-hand paths.
    """
    monkeypatch.setattr(tempfile, "mkdtemp", lambda **kw: str(tmp_path))

    f = _FakeUploadedFile("/etc/cron.d/x", b"poisoned")
    saved = safe_upload_path(f)

    assert saved.startswith(str(tmp_path))
    # The saved path must not have walked into /etc.
    assert not saved.startswith("/etc/")


def test_normal_filename_is_preserved(tmp_path, monkeypatch):
    """A legitimate upload name must round-trip cleanly."""
    monkeypatch.setattr(tempfile, "mkdtemp", lambda **kw: str(tmp_path))

    f = _FakeUploadedFile("triage-archive.zip", b"data")
    saved = safe_upload_path(f)

    assert os.path.basename(saved) == "triage-archive.zip"
    assert os.path.isfile(saved)


def test_pathological_filename_falls_back_to_upload(tmp_path, monkeypatch):
    """secure_filename returns "" for some inputs (all dots, all spaces).

    The helper must fall back to a default name rather than save with
    an empty basename.
    """
    monkeypatch.setattr(tempfile, "mkdtemp", lambda **kw: str(tmp_path))

    f = _FakeUploadedFile("...", b"data")
    saved = safe_upload_path(f)

    assert os.path.basename(saved) == "upload"


# ---------------------------------------------------------------------------
# Per-request isolation
# ---------------------------------------------------------------------------

def test_two_uploads_with_same_name_do_not_collide(tmp_path, monkeypatch):
    """Concurrent requests with identical filenames must not overwrite.

    Pre-fix, both writes went to /tmp/<filename> -- the second request
    silently replaced the first. With per-request mkdtemp this can't
    happen.
    """
    real_mkdtemp = tempfile.mkdtemp

    def scoped_mkdtemp(**kw):
        kw["dir"] = str(tmp_path)
        return real_mkdtemp(**kw)

    monkeypatch.setattr(tempfile, "mkdtemp", scoped_mkdtemp)

    f1 = _FakeUploadedFile("upload.zip", b"first")
    f2 = _FakeUploadedFile("upload.zip", b"second")
    path1 = safe_upload_path(f1)
    path2 = safe_upload_path(f2)

    assert path1 != path2, "two requests collided on the same path"
    with open(path1, "rb") as fh:
        assert fh.read() == b"first"
    with open(path2, "rb") as fh:
        assert fh.read() == b"second"


# ---------------------------------------------------------------------------
# stand-alone runner so this works without pytest installed
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    try:
        import pytest
    except ImportError:
        # Minimal smoke without pytest -- just the path-traversal assertion.
        print("pytest not installed; running smoke test inline.", file=sys.stderr)
        with tempfile.TemporaryDirectory() as td:
            real = tempfile.mkdtemp
            tempfile.mkdtemp = lambda **kw: real(prefix=kw.get("prefix", ""), dir=td)
            try:
                f = _FakeUploadedFile("../../etc/passwd", b"x")
                p = safe_upload_path(f)
                assert p.startswith(td), f"escaped: {p}"
                print(f"smoke OK -- escaped path neutralised: {p}", file=sys.stderr)
            finally:
                tempfile.mkdtemp = real
        sys.exit(0)
    sys.exit(pytest.main([__file__, "-v"]))

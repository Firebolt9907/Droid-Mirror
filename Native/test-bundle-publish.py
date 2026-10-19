#!/usr/bin/env python3
"""Verify whole-bundle replacement preserves signed-file inode identity."""
import importlib.util
from pathlib import Path
import tempfile

spec = importlib.util.spec_from_file_location("app_bundle", Path(__file__).resolve().parents[1] / "tools/app-bundle.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory(prefix="droidmirror-publish-") as folder:
    root = Path(folder)
    old, new = root / "Installed.app", root / "Candidate.app"
    for app, content in [(old, b"old mapped executable"), (new, b"new signed executable")]:
        (app / "Contents").mkdir(parents=True)
        (app / "Contents/Host").write_bytes(content)
    previous = old / "Contents/Host"
    candidate = new / "Contents/Host"
    old_inode, new_inode = previous.stat().st_ino, candidate.stat().st_ino
    # Model a process keeping the old executable mapped/open during publication.
    with previous.open("rb") as running:
        module.swap(new, old)
        assert previous.stat().st_ino == new_inode
        assert candidate.stat().st_ino == old_inode
        assert running.read() == b"old mapped executable"
        assert previous.read_bytes() == b"new signed executable"
        module.swap(new, old)  # Rollback must retain both bundles as well.
        assert previous.stat().st_ino == old_inode
        assert candidate.stat().st_ino == new_inode
    fresh = root / "Fresh.app"
    module.swap(new, fresh)
    assert (fresh / "Contents/Host").stat().st_ino == new_inode
    try:
        module.swap(new, old)
        raise AssertionError("Missing candidate accepted")
    except ValueError:
        assert previous.stat().st_ino == old_inode
print("PASS: atomic replacement, old executable preservation, rollback, first install, failed candidate")

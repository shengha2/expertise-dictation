#!/usr/bin/env python3
"""Isolated installer regression fixtures; never install, sign, or launch the real app."""
from pathlib import Path
import hashlib
import os
import plistlib
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def bundle(path, marker, product="Expertise Dictation", bundle_id="com.hao.fndictate"):
    (path / "Contents/MacOS").mkdir(parents=True)
    (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": bundle_id, "CFBundleExecutable": "FnDictate",
        "CFBundleDisplayName": product, "CFBundleName": product,
        "CFBundleShortVersionString": "1.1.2",
    }))
    exe = path / "Contents/MacOS/FnDictate"
    exe.write_text('#!/bin/bash\n[[ "$1" == --selftest ]] || exit 90\nexit 0\n')
    exe.chmod(0o755)
    (path / "marker.txt").write_text(marker)


def mock(directory, name, body):
    path = directory / name
    path.write_text("#!/bin/bash\nset -eu\n" + body)
    path.chmod(0o755)


def run_case(base, name):
    case = base / name
    source = case / "build"
    installed = case / "Applications"
    backup = case / "Backups"
    mocks = case / "mocks"
    for p in (source, installed, mocks):
        p.mkdir(parents=True)
    app = source / "Expertise Dictation.app"
    bundle(app, "new", bundle_id="wrong.bundle" if name == "wrong-source" else "com.hao.fndictate")
    legacy = installed / "FnDictate.app"
    dest = installed / "Expertise Dictation.app"
    if name != "fresh":
        bundle(legacy, "old-legacy", product="FnDictate")
    if name in ("dual", "post-verify-failure", "move-failure"):
        bundle(dest, "old-branded")
    before = {p.name: (p / "marker.txt").read_text() for p in (legacy, dest) if p.exists()}
    mock(mocks, "pgrep", '[[ "${FIXTURE_CASE}" == running ]] && exit 0\nexit 1\n')
    mock(mocks, "codesign", '''for last; do :; done
if [[ "$FIXTURE_CASE" == stage-failure && "$last" == *".Expertise-Dictation-install."* ]]; then exit 70; fi
if [[ "$FIXTURE_CASE" == post-verify-failure && "$last" == "$INSTALL_DIR/Expertise Dictation.app" ]]; then exit 71; fi
''')
    mock(mocks, "ditto", '''if [[ "$FIXTURE_CASE" == backup-failure && "$1" == -c ]]; then exit 72; fi
exec /usr/bin/ditto "$@"
''')
    mock(mocks, "mv", '''if [[ "$FIXTURE_CASE" == move-failure && "$1" == *".Expertise-Dictation-install."*"/Expertise Dictation.app" ]]; then exit 73; fi
exec /bin/mv "$@"
''')
    sentinel = case / "existing-user-data.txt"
    sentinel.write_text("Never modify settings, keys, history, or saved recordings.")
    digest = hashlib.sha256(sentinel.read_bytes()).hexdigest()
    env = dict(os.environ, PATH=str(mocks) + ":" + os.environ["PATH"],
               BUILD_DIR=str(source), INSTALL_DIR=str(installed), BACKUP_DIR=str(backup),
               SKIP_BUILD="1", FIXTURE_CASE=name)
    run = subprocess.run([str(ROOT / "scripts/install-local.sh")], env=env,
                         capture_output=True, text=True)
    success = name in ("fresh", "legacy", "dual")
    assert (run.returncode == 0) == success, (name, run.stdout, run.stderr)
    assert hashlib.sha256(sentinel.read_bytes()).hexdigest() == digest
    assert (app / "marker.txt").read_text() == "new"
    if success:
        assert (dest / "marker.txt").read_text() == "new"
        assert not legacy.exists()
        archives = list(backup.glob("*.zip"))
        assert len(archives) == len(before), (name, archives)
        for previous, marker in before.items():
            assert any(zipfile.ZipFile(p).read(previous + "/marker.txt").decode() == marker
                       for p in archives if previous + "/marker.txt" in zipfile.ZipFile(p).namelist())
    else:
        for previous, marker in before.items():
            assert (installed / previous / "marker.txt").read_text() == marker, (name, previous)
        if "Expertise Dictation.app" not in before:
            assert not dest.exists()
    assert not list(installed.glob(".Expertise-Dictation-install*")), name
    print("PASS isolated installer:", name)


def main():
    with tempfile.TemporaryDirectory(prefix="expertise-installer-fixtures-") as temporary:
        for name in ("fresh", "legacy", "dual", "running", "wrong-source", "stage-failure",
                     "backup-failure", "move-failure", "post-verify-failure"):
            run_case(Path(temporary), name)
    print("All installer fixtures passed. Real app, user data, signing, and installations were untouched.")


if __name__ == "__main__":
    main()

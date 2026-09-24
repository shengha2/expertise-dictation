#!/usr/bin/env python3
"""Real Sparkle signature tests with disposable keys; no Keychain or installed app access."""
from pathlib import Path
import base64
import importlib.util
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def main():
    spec = importlib.util.spec_from_file_location("update_config", ROOT / "scripts/update-config.py")
    config = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(config)
    assert config.build_version("1.1.2") == "1.1.2"
    assert tuple(map(int, config.build_version("1.1.3").split("."))) > (1, 1, 2)
    print("PASS release build numbers increase with the release version")
    for invalid in ["", "1.1", "1.1.2.1", "1.100.0", "1.1.beta"]:
        try:
            config.build_version(invalid)
        except ValueError:
            continue
        raise AssertionError("invalid version accepted: " + invalid)
    print("PASS invalid build versions are rejected")
    try:
        config.validate({}, required=True)
    except ValueError:
        pass
    else:
        raise AssertionError("unconfigured public release accepted")
    print("PASS public release requires secure feed and public key")
    sparkle = Path(subprocess.check_output([str(ROOT / "scripts/fetch-sparkle.sh")], text=True).strip())
    with tempfile.TemporaryDirectory(prefix="expertise-update-signatures-") as temporary:
        directory = Path(temporary)
        key = directory / "fixture-key"
        key.write_bytes(base64.b64encode(os.urandom(32)))
        key.chmod(0o600)
        archive = directory / "fixture.zip"
        archive.write_bytes(b"Disposable signature fixture; not an app or an update.\n")
        tool = [str(sparkle / "bin/sign_update"), "--ed-key-file", str(key)]

        def run(arguments, success=True):
            result = subprocess.run(tool + arguments, capture_output=True, text=True)
            assert (result.returncode == 0) == success, "unexpected Sparkle signing/verification result"
            return result.stdout.strip()

        signature = run(["-p", str(archive)])
        run(["--verify", str(archive), signature])
        print("PASS real Sparkle Ed25519 archive signature verifies")
        archive.write_bytes(archive.read_bytes() + b"tampered")
        run(["--verify", str(archive), signature], success=False)
        print("PASS real Sparkle rejects a tampered archive")
        feed = directory / "appcast.xml"
        feed.write_text('<?xml version="1.0"?><rss version="2.0"><channel><title>Fixture only</title></channel></rss>\n')
        run(["-p", str(feed)])
        run(["--verify", str(feed)])
        print("PASS real Sparkle signed feed verifies")
        feed.write_text(feed.read_text().replace("Fixture only", "Tampered title"))
        run(["--verify", str(feed)], success=False)
        print("PASS real Sparkle rejects a tampered feed")
    print("Disposable keys deleted. No production key, Keychain, feed publication, app update or installation occurred.")


if __name__ == "__main__":
    main()

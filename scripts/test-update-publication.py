#!/usr/bin/env python3
"""Mocked publication gates/output. No real Apple, Keychain, network or update actions."""
from pathlib import Path
import base64
import json
import os
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
PUBLIC = base64.b64encode(bytes([42]) * 32).decode()
FEED = "https://updates.sparkle-project.org/appcast.xml"


def executable(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/usr/bin/env python3\n" + content)
    path.chmod(0o755)


def main():
    with tempfile.TemporaryDirectory(prefix="expertise-publication-fixtures-") as temporary:
        root = Path(temporary)
        (root / "scripts").mkdir()
        for name in ("prepare-update.py", "update-config.py", "verify-release-app.py"):
            shutil.copy2(ROOT / "scripts" / name, root / "scripts" / name)
        executable(root / "scripts/fetch-sparkle.sh", "import os\nprint(os.environ['FIXTURE_SPARKLE'])\n")
        app = root / "template/Expertise Typer.app"
        base = app / "Contents/Frameworks/Sparkle.framework/Versions/B"
        for helper in ("Updater.app", "XPCServices/Installer.xpc", "XPCServices/Downloader.xpc"):
            (base / helper).mkdir(parents=True)
        (base / "Autoupdate").write_text("fixture")
        info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
        info.update(CFBundleVersion="1.1.3", CFBundleShortVersionString="1.1.3", SUFeedURL=FEED, SUPublicEDKey=PUBLIC)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        dmg = root / "Expertise-Typer-1.1.3.dmg"
        dmg.write_text("Mock DMG, not installable.")
        mocks = root / "mocks"
        common = "import os, sys, pathlib, shutil, plistlib\na=sys.argv[1:]\nf=os.environ['FIXTURE_FAILURE']\n"
        executable(mocks / "hdiutil", common + '''if a[0]=='attach':
    mount=pathlib.Path(a[a.index('-mountpoint')+1])
    shutil.copytree(os.environ['FIXTURE_APP'],mount/'Expertise Typer.app')
''')
        executable(mocks / "codesign", common + '''if '-dv' in a:
    print('Authority=Developer ID Application: Fixture (FIXTURE123)\\nTeamIdentifier=FIXTURE123\\nflags=0x10000(runtime)\\nTimestamp=Fixture',file=sys.stderr)
elif '--entitlements' in a:
    value={'com.apple.security.device.audio-input':True} if a[-1].endswith('Expertise Typer.app') else {}
    sys.stdout.buffer.write(plistlib.dumps(value))
''')
        executable(mocks / "xcrun", common + "sys.exit(1 if f=='notary' else 0)\n")
        executable(mocks / "spctl", common + "sys.exit(1 if f=='gatekeeper' else 0)\n")
        sparkle = root / "sparkle"
        executable(sparkle / "bin/generate_keys", common + "print('wrong-public-key' if f=='key_mismatch' else " + repr(PUBLIC) + ")\n")
        executable(sparkle / "bin/sign_update", common + '''if '--verify' in a:
    xml=next((pathlib.Path(x) for x in a if x.endswith('.xml')),None)
    if xml is not None:
        bad = (xml.name=='previous.xml' and f=='previous_signature') or (xml.name=='appcast.xml' and f=='feed_signature')
    else: bad=f=='archive_signature'
    sys.exit(1 if bad else 0)
elif '-p' in a:
    import base64
    print(base64.b64encode(bytes([43])*64).decode())
else:
    path=pathlib.Path(a[-1])
    path.write_text(path.read_text()+'\\n<!-- Mock signature, no cryptographic evidence. -->\\n')
''')
        env = dict(os.environ, PATH=str(mocks) + ":" + os.environ['PATH'], FIXTURE_APP=str(app), FIXTURE_SPARKLE=str(sparkle))
        cases = ("first", "followup", "notary", "gatekeeper", "unconfigured", "key_mismatch", "previous_signature", "previous_version", "previous_url", "archive_signature", "feed_signature", "local")
        for case in cases:
            current = dict(info)
            if case == "unconfigured":
                current.pop("SUFeedURL")
                current.pop("SUPublicEDKey")
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(current))
            output = root / ("publish-" + case)
            source = dmg
            if case == "local":
                source = root / "Expertise-Typer-1.1.3-local.dmg"
                source.write_bytes(dmg.read_bytes())
            command = ["python3", str(root / "scripts/prepare-update.py"), "--dmg", str(source), "--output", str(output),
                       "--download-base", "https://updates.sparkle-project.org/releases/"]
            if case in ("followup", "previous_signature", "previous_version", "previous_url"):
                previous = root / "previous.xml"
                prior_version = "1.1.3" if case == "previous_version" else "1.1.2"
                prior_url = FEED + "/wrong" if case == "previous_url" else FEED
                previous.write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:atom="http://www.w3.org/2005/Atom"><channel><atom:link rel="self" href="'+prior_url+'"/><item><sparkle:version>'+prior_version+'</sparkle:version></item></channel></rss>')
                command += ["--previous-appcast", str(previous)]
            else:
                command += ["--first-release"]
            result = subprocess.run(command, env=dict(env, FIXTURE_FAILURE=case), capture_output=True, text=True)
            if case in ("first", "followup"):
                assert result.returncode == 0, (case, result.stdout, result.stderr)
                assert {p.name for p in output.iterdir()} == {dmg.name, "appcast.xml", "SHA256SUMS", "publication-receipt.json"}
                receipt = json.loads((output / "publication-receipt.json").read_text())
                assert receipt["uploaded"] is False and receipt["publicKey"] == PUBLIC
                assert receipt["feedURL"] == FEED and (output / dmg.name).read_bytes() == dmg.read_bytes()
                assert ("1.1.2" in (output / "appcast.xml").read_text()) == (case == "followup")
                before = (output / "appcast.xml").read_bytes()
                again = subprocess.run(command, env=dict(env, FIXTURE_FAILURE=case), capture_output=True, text=True)
                assert again.returncode != 0 and before == (output / "appcast.xml").read_bytes()
                print("PASS mocked publication:", case, "reviewed output only, history preserved, existing output refused")
            else:
                assert result.returncode != 0 and not output.exists(), (case, result.stdout, result.stderr)
                print("PASS mocked publication:", case, "cannot produce a publish directory")
            assert not list(root.glob(".expertise-update-*")) and not list(root.glob(".*.lock"))
    print("All twelve publication fixtures passed. No Apple validation, Keychain access, network, installation or publication occurred.")


if __name__ == "__main__":
    main()

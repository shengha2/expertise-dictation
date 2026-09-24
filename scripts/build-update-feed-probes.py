#!/usr/bin/env python3
"""Build standalone Sparkle information probes. Never contacts the feed or runs an update."""
from pathlib import Path
import argparse
import base64
import hashlib
import json
import plistlib
import re
import subprocess
import tempfile
import uuid
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
SPARKLE_SHA = "c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
FEED = "https://github.com/shengha2/expertise-dictation-releases/releases/latest/download/appcast.xml"
PUBLIC_KEY = "LP6+AEIGK09yvLZH45BwguqSlRzL9DNxp1GapNN9nO8="


def run(*command):
    subprocess.run([str(part) for part in command], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new build directory; existing paths are refused")
    parser.add_argument("--versions", nargs="+", default=["1.1.3", "1.1.4"],
                        help="isolated host versions to simulate (three numeric components each)")
    args = parser.parse_args()
    if any(not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) for version in args.versions):
        parser.error("each version must have three numeric components, such as 1.1.6")
    if len(set(args.versions)) != len(args.versions):
        parser.error("versions must be unique")
    output = args.output.absolute()
    if output.exists() or output.is_symlink():
        parser.error("output exists; choose a new diagnostic build directory")
    archive = ROOT / "build/vendor/Sparkle-2.10.0.tar.xz"
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SPARKLE_SHA:
        parser.error("cached Sparkle archive checksum mismatch")
    assert len(base64.b64decode(PUBLIC_KEY, validate=True)) == 32 and urlsplit(FEED).scheme == "https"
    output.mkdir(parents=True)
    source = ROOT / "scripts/SparkleFeedProbe.m"
    with tempfile.TemporaryDirectory(prefix=".probe-vendor-", dir=output) as temporary:
        vendor = Path(temporary)
        run("tar", "-xJf", archive, "-C", vendor)
        binary = vendor / "FeedProbe"
        run("xcrun", "clang", "-fobjc-arc", "-fmodules", "-Wall", "-Werror", "-mmacosx-version-min=14.0",
            "-framework", "AppKit", "-F", vendor, "-framework", "Sparkle",
            "-Wl,-rpath,@executable_path/../Frameworks", source, "-o", binary)
        prepared = []
        for version in args.versions:
            app = output / ("Feed Probe " + version + ".app")
            contents = app / "Contents"
            (contents / "MacOS").mkdir(parents=True)
            (contents / "Frameworks").mkdir()
            run("ditto", binary, contents / "MacOS/FeedProbe")
            run("ditto", vendor / "Sparkle.framework", contents / "Frameworks/Sparkle.framework")
            identifier = "com.hao.expertise-dictation.feed-probe." + uuid.uuid4().hex
            info = {
                "CFBundleIdentifier": identifier, "CFBundleExecutable": "FeedProbe", "CFBundleName": "Feed Probe",
                "CFBundlePackageType": "APPL", "CFBundleVersion": version, "CFBundleShortVersionString": version,
                "NSPrincipalClass": "NSApplication", "LSUIElement": True, "LSMinimumSystemVersion": "14.0",
                "SUFeedURL": FEED, "SUPublicEDKey": PUBLIC_KEY, "SURequireSignedFeed": True,
                "SUVerifyUpdateBeforeExtraction": True, "SUSignedFeedFailureExpirationInterval": 0,
                "SUEnableAutomaticChecks": False, "SUAutomaticallyUpdate": False, "SUAllowsAutomaticUpdates": False,
                "SUEnableSystemProfiling": False,
            }
            (contents / "Info.plist").write_bytes(plistlib.dumps(info))
            run("codesign", "--force", "--sign", "-", app)
            run("codesign", "--verify", "--deep", "--strict", app)
            prepared.append({"app": str(app), "bundleID": identifier, "currentVersion": version,
                             "executableSHA256": hashlib.sha256((contents / "MacOS/FeedProbe").read_bytes()).hexdigest()})
    (output / "prepared.json").write_text(json.dumps({"scope": "Prepared only; no feed request or update performed",
        "sourceSHA256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "builderSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), "sparkleArchiveSHA256": SPARKLE_SHA,
        "feedURL": FEED, "publicKey": PUBLIC_KEY, "probes": prepared}, indent=2) + "\n")
    print("Prepared " + str(output / "prepared.json"))
    print("Run each Contents/MacOS/FeedProbe only after publication with --expect update|no-update --expected-version PUBLISHED_VERSION --report /absolute/new-report.json --timeout 90")


if __name__ == "__main__":
    main()

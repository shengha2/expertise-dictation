#!/usr/bin/env python3
"""Read-only Developer ID checks for the app and every embedded Sparkle helper."""
from pathlib import Path
import argparse
import plistlib
import re
import subprocess


def run(*args):
    result = subprocess.run(args, capture_output=True, check=True)
    return result.stdout + result.stderr


def verify(app):
    app = Path(app)
    run("codesign", "--verify", "--deep", "--strict", "--all-architectures", str(app))
    framework = app / "Contents/Frameworks/Sparkle.framework"
    base = framework / "Versions/B"
    objects = [app, framework, base / "Autoupdate", base / "Updater.app",
               base / "XPCServices/Installer.xpc", base / "XPCServices/Downloader.xpc"]
    team = None
    for target in objects:
        if not target.exists():
            raise ValueError("missing signed code: " + str(target))
        # Both slices must carry the same publisher identity and hardened runtime.
        for architecture in ("arm64", "x86_64"):
            details = run("codesign", "-dv", "--verbose=4", "--arch", architecture, str(target)).decode()
            match = re.search(r"^TeamIdentifier=([A-Z0-9]+)$", details, re.MULTILINE)
            if not match or "Authority=Developer ID Application:" not in details or "(runtime)" not in details or "Timestamp=" not in details:
                raise ValueError("Developer ID, hardened runtime, and timestamp required: " + str(target))
            if team is None:
                team = match[1]
            if match[1] != team:
                raise ValueError("mixed signing teams inside app: " + str(target))
            result = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", "--arch", architecture, str(target)],
                                    capture_output=True, check=True)
            entitlements = plistlib.loads(result.stdout) if result.stdout.strip() else {}
            expected = {"com.apple.security.device.audio-input": True} if target == app else {}
            if entitlements != expected:
                raise ValueError("unexpected release entitlements: " + str(target))
    return team


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app")
    args = parser.parse_args()
    print("All app/Sparkle slices use Developer ID team " + verify(args.app) + ", hardened runtime and approved entitlements.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        raise SystemExit("error: " + str(error))

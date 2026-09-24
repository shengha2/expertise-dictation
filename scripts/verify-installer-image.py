#!/usr/bin/env python3
"""Inspect a real DMG read-only, without Finder UI, signing or notarization claims.

Uses the already installed, pinned packaging venv. No packages are downloaded.
The image is mounted privately at a unique temporary path and always detached.
Evidence contains artifact names, hashes and layout metadata, never local paths.
"""
import argparse
import hashlib
import importlib.metadata
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parent.parent
PRODUCT = "Expertise Typer"
APP_NAME = PRODUCT + ".app"
GUIDE_NAME = "Guide and licenses"

# AppKit reads both TIFF representations without launching NSApplication or a UI.
IMAGE_INSPECTOR = r'''
#import <AppKit/AppKit.h>
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSArray *reps = [NSBitmapImageRep imageRepsWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
        if (reps.count == 0) return 1;
        NSMutableArray *output = [NSMutableArray new];
        for (NSBitmapImageRep *rep in reps) {
            [output addObject:@{@"pixelsWide": @(rep.pixelsWide), @"pixelsHigh": @(rep.pixelsHigh),
                @"pointsWide": @(rep.size.width), @"pointsHigh": @(rep.size.height)}];
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:output options:0 error:nil];
        if (!json) return 1;
        fwrite(json.bytes, 1, json.length, stdout);
        return 0;
    }
}
'''


class VerificationFailure(Exception):
    """Messages must be fixed descriptions, without local paths or private data."""


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def command(arguments, label, timeout=60):
    try:
        result = subprocess.run([str(arg) for arg in arguments], capture_output=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        raise VerificationFailure(label + " could not complete") from None
    if result.returncode:
        raise VerificationFailure(label + " failed")
    return result.stdout


def check(report, name, condition):
    report["checks"].append({"name": name, "passed": bool(condition)})
    if not condition:
        raise VerificationFailure(name)


def regular(path):
    return path.is_file() and not path.is_symlink() and path.stat().st_size > 0


def pinned_runtime():
    runtime = ROOT / "build/vendor/dmg-tools"
    executable = runtime / "bin/python3"
    fingerprint = runtime / "requirements.sha256"
    requirements = ROOT / "scripts/requirements-dmg.txt"
    if (not executable.is_file() or not fingerprint.is_file() or
            fingerprint.read_text().strip() != digest(requirements)):
        raise VerificationFailure("Pinned DMG build dependencies are not installed or do not match their lockfile")
    if Path(sys.prefix).resolve() != runtime.resolve():
        os.execv(str(executable), [str(executable), str(Path(__file__).resolve()), *sys.argv[1:]])
    versions = {}
    for line in requirements.read_text().splitlines():
        match = re.match(r"([\w-]+)==([^\s]+)", line)
        if match:
            package, expected = match.groups()
            installed = importlib.metadata.version(package)
            if installed != expected:
                raise VerificationFailure("Installed packaging dependency version differs from the lockfile")
            versions[package] = installed
    return versions


def bookmark_strings(value):
    if isinstance(value, str):
        yield unquote(value)
    elif isinstance(value, dict):
        for child in value.values():
            yield from bookmark_strings(child)
    elif isinstance(value, (tuple, list)):
        for child in value:
            yield from bookmark_strings(child)
    elif hasattr(value, "absolute"):
        yield unquote(value.absolute)


def inspect_mount(volume, temporary, report, expected_version):
    from ds_store import DSStore

    applications = [p for p in volume.iterdir() if p.suffix == ".app"]
    check(report, "Exactly one renamed application bundle", len(applications) == 1 and applications[0].name == APP_NAME
          and applications[0].is_dir() and not applications[0].is_symlink())
    app = applications[0]
    info_file = app / "Contents/Info.plist"
    check(report, "Application Info.plist exists", regular(info_file))
    info = plistlib.loads(info_file.read_bytes())
    check(report, "Existing bundle identity and executable are preserved",
          info.get("CFBundleIdentifier") == "com.hao.fndictate" and info.get("CFBundleExecutable") == "FnDictate")
    check(report, "Application displays Expertise Typer", info.get("CFBundleDisplayName") == PRODUCT)
    version = info.get("CFBundleShortVersionString", "")
    check(report, "Application version matches the requested release", isinstance(version, str)
          and re.fullmatch(r"\d+(?:\.\d+)+", version) is not None and version == expected_version)
    check(report, "Application executable is present", regular(app / "Contents/MacOS/FnDictate"))
    report["application"] = {"name": APP_NAME, "bundleIdentifier": info["CFBundleIdentifier"], "version": version}
    shortcut = volume / "Applications"
    check(report, "Applications shortcut targets /Applications", shortcut.is_symlink() and os.readlink(shortcut) == "/Applications")
    guide = volume / GUIDE_NAME
    check(report, "Guide and licenses includes a nonempty installation readme",
          guide.is_dir() and not guide.is_symlink() and regular(guide / "Read me first.txt"))

    app_icon = app / "Contents/Resources/AppIcon.icns"
    volume_icon = volume / ".VolumeIcon.icns"
    check(report, "Bundle metadata names the included application icon", info.get("CFBundleIconFile") in ("AppIcon", "AppIcon.icns"))
    check(report, "Application and disk-volume icons are present", regular(app_icon) and regular(volume_icon))
    app_icon_hash, volume_icon_hash = digest(app_icon), digest(volume_icon)
    check(report, "Disk-volume logo exactly matches the application logo", app_icon_hash == volume_icon_hash)
    report["iconSHA256"] = app_icon_hash
    finder_info = bytes.fromhex(command(["/usr/bin/xattr", "-px", "com.apple.FinderInfo", volume], "Volume Finder metadata read").decode())
    check(report, "Volume custom-icon Finder flag is enabled", len(finder_info) >= 10 and bool(int.from_bytes(finder_info[8:10], "big") & 0x0400))

    store_file = volume / ".DS_Store"
    check(report, "Finder layout metadata is present", regular(store_file))
    with DSStore.open(str(store_file), "r") as store:
        icon_settings = store["."]["icvp"]
        window_settings = store["."]["bwsp"]
        bookmark = store["."]["pBBk"]
        default_view = store["."]["icvl"]
        positions = {name: store[name]["Iloc"] for name in (APP_NAME, "Applications", GUIDE_NAME)}
    if isinstance(default_view, tuple):
        default_view = default_view[-1]
    check(report, "Finder opens in icon view", default_view == b"icnv")
    bounds = re.fullmatch(r"\{\{(-?\d+),\s*(-?\d+)\},\s*\{(\d+),\s*(\d+)\}\}", window_settings.get("WindowBounds", ""))
    check(report, "Finder window bounds are valid", bounds is not None)
    width, height = map(int, bounds.groups()[2:])
    icon_size = float(icon_settings.get("iconSize", 0))
    label_height = float(icon_settings.get("textSize", 0)) * 2
    check(report, "Finder icons fit completely inside the window", width > 0 and height > 0 and icon_size > 0 and
          all(isinstance(position, tuple) and len(position) == 2 and
              icon_size / 2 <= position[0] <= width - icon_size / 2 and
              icon_size / 2 <= position[1] <= height - icon_size / 2 - label_height for position in positions.values()))
    points = list(positions.values())
    check(report, "Installer icons do not overlap", all(
        abs(points[a][0] - points[b][0]) >= icon_size + 12 or
        abs(points[a][1] - points[b][1]) >= icon_size + label_height + 12
        for a in range(len(points)) for b in range(a + 1, len(points))))
    report["layout"] = {"windowSize": [width, height], "iconSize": icon_size,
                        "iconLocations": {name: list(point) for name, point in positions.items()}}
    backgrounds = [p for p in volume.glob(".background.*") if regular(p)]
    check(report, "Finder references one real background image", icon_settings.get("backgroundType") == 2 and len(backgrounds) == 1)
    background = backgrounds[0]
    report["background"] = {"fileName": background.name, "sha256": digest(background)}
    toc = bookmark.tocs[0][1] if bookmark.tocs else {}
    strings = list(bookmark_strings(bookmark.tocs))
    check(report, "Background bookmark contains only portable target-volume metadata",
          len(bookmark.tocs) == 1 and 0x2000 not in toc and 0x2040 not in toc and
          0xc011 not in toc and 0xc012 not in toc and toc.get(0x1004) == [background.name] and
          len(toc.get(0x1005, [])) == 1 and not any(
              fragment in value for value in strings for fragment in ("/Users/", "/private/", "/var/", "/tmp/")))
    bookmark_file = temporary / "background.bookmark"
    bookmark_file.write_bytes(bookmark.to_bytes())
    native_helper = temporary / "native-background-bookmark"
    command(["clang", "-fobjc-arc", "-fmodules", "-framework", "Foundation",
             ROOT / "scripts/native-background-bookmark.m", "-o", native_helper], "Native bookmark validator compilation")
    command([native_helper, "validate", bookmark_file, background], "Native background bookmark resolution after remount")
    check(report, "Native background bookmark resolves to the exact image after private remount", True)

    image_source = temporary / "inspect-background.m"
    image_source.write_text(IMAGE_INSPECTOR)
    image_helper = temporary / "inspect-background"
    command(["clang", "-fobjc-arc", "-fmodules", "-framework", "AppKit", image_source, "-o", image_helper], "Background image inspector compilation")
    representations = json.loads(command([image_helper, background], "Background image representation inspection"))
    report["background"]["representations"] = representations
    check(report, "Background TIFF includes matching 1x and 2x Retina representations",
          background.suffix.lower() in (".tif", ".tiff") and len(representations) == 2 and
          sorted((r["pixelsWide"], r["pixelsHigh"]) for r in representations) == [(width, height), (width * 2, height * 2)] and
          all(math.isclose(r["pointsWide"], width, abs_tol=0.1) and math.isclose(r["pointsHigh"], height, abs_tol=0.1)
              for r in representations))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dmg", type=Path)
    parser.add_argument("--output", type=Path, help="Optional JSON evidence file; stdout always prints the evidence")
    parser.add_argument("--expected-version", default=(ROOT / "VERSION").read_text().strip())
    args = parser.parse_args()
    if args.output and args.output.resolve() == args.dmg.resolve():
        parser.error("JSON output must not overwrite the disk image")
    report = {"schemaVersion": 1, "artifact": args.dmg.name, "success": False, "checks": [],
              "scope": "Read-only DMG contents and Finder metadata validation; no signing, notarization, installation, or visual Finder appearance claim.",
              "microphoneUsed": False, "userPreferencesChanged": False, "networkUsed": False}
    temporary = None
    mount = None
    initial_hash = None
    try:
        report["dependencies"] = pinned_runtime()
        check(report, "Input is an existing regular DMG", regular(args.dmg) and args.dmg.suffix.lower() == ".dmg")
        image = args.dmg.resolve(strict=True)
        initial_hash = digest(image)
        report["sha256"] = initial_hash
        report["bytes"] = image.stat().st_size
        command(["hdiutil", "verify", image], "DMG checksum verification")
        check(report, "Disk-image checksum verification passes", True)
        temporary = Path(tempfile.mkdtemp(prefix="expertise-installer-verification-")).resolve()
        mount = temporary / "mounted-image"
        mount.mkdir()
        response = command(["hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount, "-plist", image], "Private read-only image mount")
        attachments = plistlib.loads(response).get("system-entities", [])
        mounted_paths = [Path(item["mount-point"]).resolve() for item in attachments if "mount-point" in item]
        check(report, "Image is mounted at the validator's isolated temporary location", mounted_paths == [mount] and os.path.ismount(mount))
        check(report, "Mounted filesystem is read-only", bool(os.statvfs(mount).f_flag & os.ST_RDONLY))
        inspect_mount(mount, temporary, report, args.expected_version)
    except VerificationFailure as error:
        report["error"] = str(error)
    except Exception as error:
        # Exception text can include local paths or malformed file content. Record
        # only its type; fixed check descriptions identify the failed stage.
        report["error"] = "Installer metadata inspection failed (" + type(error).__name__ + ")"
    finally:
        detached = True
        if mount is not None and os.path.ismount(mount):
            detached = False
            for force in (False, True):
                try:
                    command(["hdiutil", "detach", *(["-force"] if force else []), mount], "Temporary image detach", timeout=30)
                    detached = not os.path.ismount(mount)
                    if detached:
                        break
                except VerificationFailure:
                    pass
        report["temporaryMountDetached"] = detached
        if not detached:
            report["error"] = "Temporary validation mount could not be detached"
        # Never recursively clean a still-mounted volume, even on a failure.
        if temporary is not None and detached:
            shutil.rmtree(temporary, ignore_errors=True)
        if initial_hash is not None:
            try:
                report["imageUnchanged"] = digest(args.dmg.resolve(strict=True)) == initial_hash
            except OSError:
                report["imageUnchanged"] = False
            if not report["imageUnchanged"]:
                report["error"] = "The disk image changed during read-only validation"
    report["success"] = "error" not in report and bool(report["checks"]) and all(item["passed"] for item in report["checks"])
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded)
    print(encoded, end="")
    return 0 if report["success"] else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Prepare a signed Sparkle feed from a notarized DMG. Never uploads or installs."""
from pathlib import Path
import argparse
import base64
import datetime
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
from urllib.parse import quote, urlsplit
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ATOM = "http://www.w3.org/2005/Atom"
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("atom", ATOM)


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


config = module("update_config", "update-config.py")
release = module("verify_release_app", "verify-release-app.py")


def run(*args):
    return subprocess.run([str(arg) for arg in args], check=True, capture_output=True, text=True).stdout.strip()


def public_url(value):
    # Use exactly the same public URL rules as the embedded updater configuration.
    config.validate({"SUFeedURL": value, "SUPublicEDKey": base64.b64encode(bytes(32)).decode(),
                     "SUVerifyUpdateBeforeExtraction": True, "SURequireSignedFeed": True}, required=True)
    return value


def version_tuple(value):
    return tuple(int(part) for part in config.build_version(value).split("."))


def parse_feed(path):
    data = Path(path).read_bytes()
    if len(data) > 5_000_000 or b"<!DOCTYPE" in data.upper() or b"<!ENTITY" in data.upper():
        raise ValueError("feed must be at most5MB and contain no DTD/entities")
    result = ET.fromstring(data)
    if result.tag != "rss" or result.find("channel") is None:
        raise ValueError("expected an RSS appcast channel")
    return result


def prior_versions(feed, expected_url):
    channel = feed.find("channel")
    self_link = channel.find("{" + ATOM + "}link")
    if self_link is None or self_link.get("rel") != "self" or self_link.get("href") != expected_url:
        raise ValueError("previous signed feed does not identify this exact SUFeedURL")
    versions = []
    for item in channel.findall("item"):
        versions.append(version_tuple(item.findtext("{" + SPARKLE + "}version", "")))
        for enclosure in item.iter("enclosure"):
            public_url(enclosure.get("url", ""))
    return versions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dmg", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path, help="new directory; existing output is never overwritten")
    parser.add_argument("--download-base", required=True, help="publisher-owned HTTPS directory ending in /")
    parser.add_argument("--account", default="ExpertiseDictation", help="existing Sparkle signing-key account in macOS Keychain")
    previous = parser.add_mutually_exclusive_group(required=True)
    previous.add_argument("--previous-appcast", type=Path, help="exact latest published signed feed")
    previous.add_argument("--first-release", action="store_true", help="explicitly initialize a new feed with no prior releases")
    parser.add_argument("--release-notes", type=Path, help="reviewed plain text, embedded inside the signed feed")
    args = parser.parse_args()
    dmg = args.dmg.resolve(strict=True)
    output = args.output.absolute()
    if output.exists() or output.is_symlink():
        raise ValueError("output already exists; preserve it and choose a new release directory")
    if dmg.suffix != ".dmg" or "-local" in dmg.stem:
        raise ValueError("use a public notarized release DMG, never a local development artifact")
    base = public_url(args.download_base)
    if not base.endswith("/"):
        raise ValueError("download-base must end in /")
    notes = args.release_notes.read_text() if args.release_notes else "Expertise Dictation maintenance update."
    if len(notes) > 100_000:
        raise ValueError("release notes are too large")
    # Validate a private snapshot so a concurrent source replacement cannot change
    # the bytes between Apple's checks and the Ed25519 signing step.
    with tempfile.TemporaryDirectory(prefix="expertise-update-verified-") as verified:
        snapshot = Path(verified) / dmg.name
        shutil.copy2(dmg, snapshot)
        dmg = snapshot
        if args.previous_appcast:
            prior_directory = Path(verified) / "previous"
            prior_directory.mkdir()
            prior_snapshot = prior_directory / args.previous_appcast.name
            shutil.copy2(args.previous_appcast, prior_snapshot)
            args.previous_appcast = prior_snapshot
        # All Apple gates are checked before accessing a signing key or creating output.
        run("hdiutil", "verify", dmg)
        run("codesign", "--verify", "--strict", dmg)
        details = subprocess.run(["codesign", "-dv", "--verbose=4", str(dmg)], capture_output=True, check=True, text=True).stderr
        if "Authority=Developer ID Application:" not in details or "Timestamp=" not in details:
            raise ValueError("DMG needs a timestamped Developer ID signature")
        run("xcrun", "stapler", "validate", dmg)
        run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", dmg)
        with tempfile.TemporaryDirectory(prefix="expertise-update-mount-") as mounting:
            mount = Path(mounting) / "image"
            mount.mkdir()
            attached = False
            try:
                run("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, dmg)
                attached = True
                apps = list(mount.glob("*.app"))
                app = mount / "Expertise Dictation.app"
                if apps != [app] or app.is_symlink():
                    raise ValueError("DMG must contain exactly Expertise Dictation.app")
                info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
                if info.get("CFBundleIdentifier") != "com.hao.fndictate" or info.get("CFBundleExecutable") != "FnDictate" or info.get("CFBundleDisplayName") != "Expertise Dictation":
                    raise ValueError("unexpected app identity")
                config.validate(info, required=True)
                version = info.get("CFBundleVersion", "")
                version_tuple(version)
                if version != info.get("CFBundleShortVersionString"):
                    raise ValueError("build and release versions must match this project's version convention")
                team = release.verify(app)
                if "TeamIdentifier=" + team not in details.splitlines():
                    raise ValueError("DMG and app signing teams differ")
                run("xcrun", "stapler", "validate", app)
                run("spctl", "--assess", "--type", "execute", app)
            finally:
                if attached:
                    run("hdiutil", "detach", mount)
        # Existing public key lookup only; this script never generates/exports private keys.
        sparkle = Path(run(ROOT / "scripts/fetch-sparkle.sh"))
        signer = sparkle / "bin/sign_update"
        public_key = run(sparkle / "bin/generate_keys", "--account", args.account, "-p")
        if public_key != info["SUPublicEDKey"]:
            raise ValueError("Keychain public key does not match the key embedded in the notarized app")
        if args.previous_appcast:
            run(signer, "--account", args.account, "--verify", args.previous_appcast)
            feed = parse_feed(args.previous_appcast)
            versions = prior_versions(feed, info["SUFeedURL"])
            if versions and version_tuple(version) <= max(versions):
                raise ValueError("new CFBundleVersion must exceed every previous published version")
        else:
            feed = ET.Element("rss", {"version": "2.0"})
            channel = ET.SubElement(feed, "channel")
            ET.SubElement(channel, "title").text = "Expertise Dictation updates"
            ET.SubElement(channel, "{" + ATOM + "}link", {"href": info["SUFeedURL"], "rel": "self", "type": "application/rss+xml"})
            ET.SubElement(channel, "description").text = "Signed updates for Expertise Dictation."
        output.parent.mkdir(parents=True, exist_ok=True)
        lock = output.parent / ("." + output.name + ".lock")
        lock.mkdir()  # Refuse concurrent publishers targeting the same output.
        try:
            with tempfile.TemporaryDirectory(prefix=".expertise-update-", dir=output.parent) as temporary:
                staging = Path(temporary)
                archive = staging / dmg.name
                shutil.copy2(dmg, archive)
                signature = run(signer, "--account", args.account, "-p", archive)
                if len(base64.b64decode(signature, validate=True)) != 64:
                    raise ValueError("unexpected Ed25519 archive signature")
                run(signer, "--account", args.account, "--verify", archive, signature)
                item = ET.Element("item")
                ET.SubElement(item, "title").text = "Expertise Dictation " + version
                ET.SubElement(item, "{" + SPARKLE + "}version").text = version
                ET.SubElement(item, "{" + SPARKLE + "}shortVersionString").text = version
                ET.SubElement(item, "{" + SPARKLE + "}minimumSystemVersion").text = info.get("LSMinimumSystemVersion", "14.0")
                ET.SubElement(item, "description", {"{" + SPARKLE + "}format": "plain-text"}).text = notes
                download_url = base + quote(dmg.name)
                ET.SubElement(item, "enclosure", {"url": download_url, "type": "application/octet-stream",
                    "length": str(archive.stat().st_size), "{" + SPARKLE + "}edSignature": signature})
                feed.find("channel").insert(0, item)
                feed_path = staging / "appcast.xml"
                ET.ElementTree(feed).write(feed_path, encoding="utf-8", xml_declaration=True)
                run(signer, "--account", args.account, feed_path)
                run(signer, "--account", args.account, "--verify", feed_path)
                # Parsing after signing also catches malformed output before it can be published.
                prior_versions(parse_feed(feed_path), info["SUFeedURL"])
                hashes = {file.name: hashlib.sha256(file.read_bytes()).hexdigest() for file in (archive, feed_path)}
                (staging / "SHA256SUMS").write_text("".join(digest + "  " + name + "\n" for name, digest in hashes.items()))
                receipt = {"product": "Expertise Dictation", "version": version, "teamID": team,
                           "createdUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                           "feedURL": info["SUFeedURL"], "downloadURL": download_url,
                           "publicKey": public_key, "sha256": hashes, "uploaded": False,
                           "validation": "Developer ID, notarization, Gatekeeper, archive Ed25519, signed feed"}
                (staging / "publication-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
                if output.exists() or output.is_symlink():
                    raise ValueError("output appeared during preparation; refusing to replace it")
                staging.rename(output)
        finally:
            lock.rmdir()
        print("Prepared " + str(output))
        print("Upload the DMG first to " + download_url)
        print("Then atomically publish appcast.xml at " + info["SUFeedURL"])
        print("No files were uploaded and no installed app was modified.")



if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, plistlib.InvalidFileException, ET.ParseError, subprocess.CalledProcessError) as error:
        raise SystemExit("error: " + str(error))

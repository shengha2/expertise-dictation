#!/usr/bin/env python3
"""Validate public updater configuration; this tool never reads signing secrets."""
import argparse
import base64
import ipaddress
import os
from pathlib import Path
import plistlib
import re
from urllib.parse import urlsplit


def validate(info, required=False):
    feed = info.get("SUFeedURL", "")
    key = info.get("SUPublicEDKey", "")
    if not feed and not key and not required:
        return False
    if not isinstance(feed, str) or not isinstance(key, str):
        raise ValueError("update feed and public key must be strings")
    url = urlsplit(feed)
    if url.scheme != "https" or not url.hostname or url.username or url.password or url.fragment or url.query:
        raise ValueError("a public HTTPS update-feed URL without credentials, query or fragment is required")
    host = url.hostname.lower()
    if host == "localhost" or host.endswith((".localhost", ".local", ".invalid", ".test", ".example")) or host in ("example.com", "example.org", "example.net"):
        raise ValueError("placeholder and local update-feed hosts cannot ship")
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        address = None
    if address is not None and not address.is_global:
        raise ValueError("private or loopback update-feed hosts cannot ship")
    try:
        decoded = base64.b64decode(key, validate=True)
    except Exception as error:
        raise ValueError("invalid public Ed25519 key") from error
    if len(decoded) != 32:
        raise ValueError("public Ed25519 key must decode to32bytes")
    for name in ("SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed"):
        if info.get(name) is not True:
            raise ValueError(name + " must be enabled")
    return True


def build_version(version):
    if not re.fullmatch(r"[1-9][0-9]{0,3}\.[0-9]{1,2}\.[0-9]{1,2}", version):
        raise ValueError("VERSION must contain three numeric components (major1–9999, minor/patch0–99)")
    return version


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plist", nargs="?")
    parser.add_argument("--configure", action="store_true")
    parser.add_argument("--require", action="store_true")
    parser.add_argument("--build-version")
    args = parser.parse_args()
    if args.build_version is not None:
        print(build_version(args.build_version))
        return
    if not args.plist:
        parser.error("plist path is required")
    path = Path(args.plist)
    info = plistlib.loads(path.read_bytes())
    if args.configure:
        for environment, setting in (("UPDATE_FEED_URL", "SUFeedURL"), ("UPDATE_PUBLIC_ED_KEY", "SUPublicEDKey")):
            if environment in os.environ:
                value = os.environ[environment].strip()
                if value: info[setting] = value
                else: info.pop(setting, None)
    configured = validate(info, required=args.require)
    if args.configure:
        path.write_bytes(plistlib.dumps(info, sort_keys=False))
    print("Secure updater configuration present." if configured else "Updater unconfigured: no public feed/key embedded.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        raise SystemExit("error: " + str(error))

#!/usr/bin/env python3
"""Embed an explicit connection flavor, never a credential. Hosted builds fail closed."""
import argparse
import ipaddress
import os
import plistlib
import re
from pathlib import Path
from urllib.parse import urlsplit


def validated_origin(value):
    if not isinstance(value, str):
        raise ValueError("The free service URL must be a string containing a public HTTPS origin")
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError:
        raise ValueError("The free service URL must contain a valid HTTPS hostname and port") from None
    host = parsed.hostname or ""
    if (parsed.scheme != "https" or not host or parsed.username is not None or parsed.password is not None
            or parsed.query or parsed.fragment or parsed.path not in ("", "/")
            or port not in (None, 443) or any(c.isspace() for c in value)):
        raise ValueError("The free service URL must be an HTTPS origin without credentials, path, query or fragment")
    if host == "localhost" or host.endswith((".localhost", ".local", ".internal")) or "." not in host:
        raise ValueError("The free service needs a public hostname")
    try:
        ipaddress.ip_address(host)
    except ValueError:
        try:
            host = host.encode("idna").decode("ascii").lower()
        except UnicodeError:
            raise ValueError("The free service needs a valid public hostname") from None
        if (len(host) > 253 or not re.fullmatch(r"[a-z0-9-]+(?:\.[a-z0-9-]+)+", host)
                or all(part.isdigit() for part in host.split("."))
                or any(len(part) > 63 or part.startswith("-") or part.endswith("-") for part in host.split("."))):
            raise ValueError("The free service needs a valid public hostname")
        return "https://" + host
    raise ValueError("Use the free service's public hostname, not an IP address")


def release_requires_service_mode(version):
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version):
        raise ValueError("Release version must contain dotted numbers")
    parts = tuple(int(part) for part in version.split("."))
    return parts + (0,) * max(0, 3 - len(parts)) >= (1, 1, 9)


def validated_mode(value):
    if value not in ("personal", "hosted"):
        raise ValueError("Expertise service mode must be exactly 'personal' or 'hosted'")
    return value


def checked_configuration(info, require_hosted_origin):
    # An absent mode is legacy hosted behavior, never an implicit personal release.
    mode = validated_mode(info.get("ExpertiseServiceMode", "hosted"))
    value = info.get("ExpertiseServiceURL")
    if mode == "personal":
        if value is not None:
            raise ValueError("A personal service mode bundle must omit ExpertiseServiceURL; rebuild with EXPERTISE_SERVICE_MODE=personal")
        if os.environ.get("HOSTED_SERVICE_REQUIRED") == "1":
            raise ValueError("HOSTED_SERVICE_REQUIRED=1 conflicts with personal service mode")
    elif not value and require_hosted_origin:
        raise ValueError("A hosted distribution of version 1.1.9 or newer requires a configured public HTTPS ExpertiseServiceURL; set EXPERTISE_SERVICE_URL or explicitly select EXPERTISE_SERVICE_MODE=personal before building")
    elif value:
        validated_origin(value)
    return mode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plist", type=Path, nargs="?")
    parser.add_argument("--check-release-version", metavar="VERSION",
                        help="read-only distribution gate; inspect the built plist when given, otherwise EXPERTISE_SERVICE_MODE/URL")
    args = parser.parse_args()
    if args.check_release_version is not None:
        try:
            required = release_requires_service_mode(args.check_release_version)
            if required:
                if args.plist is not None:
                    with args.plist.open("rb") as source:
                        info = plistlib.load(source)
                else:
                    info = {"ExpertiseServiceMode": os.environ.get("EXPERTISE_SERVICE_MODE", "hosted")}
                    value = os.environ.get("EXPERTISE_SERVICE_URL", "").strip()
                    if value:
                        info["ExpertiseServiceURL"] = value
                mode = checked_configuration(info, require_hosted_origin=True)
        except (ValueError, OSError, plistlib.InvalidFileException) as error:
            parser.error(str(error))
        print(f"{mode.capitalize()} release configuration checked; no deployment or HTTP health check was performed." if required
              else "This older release does not require an explicit service flavor.")
        return
    if args.plist is None:
        parser.error("plist is required when configuring a build")
    value = os.environ.get("EXPERTISE_SERVICE_URL", "").strip()
    required = os.environ.get("HOSTED_SERVICE_REQUIRED") == "1"
    try:
        mode = validated_mode(os.environ.get("EXPERTISE_SERVICE_MODE", "hosted"))
        configuration = {"ExpertiseServiceMode": mode}
        if value:
            configuration["ExpertiseServiceURL"] = value
        checked_configuration(configuration, require_hosted_origin=required)
    except ValueError as error:
        parser.error(str(error))
    with args.plist.open("rb") as f:
        info = plistlib.load(f)
    info["ExpertiseServiceMode"] = mode
    if value:
        try:
            info["ExpertiseServiceURL"] = validated_origin(value)
        except ValueError as error:
            parser.error(str(error))
    else:
        info.pop("ExpertiseServiceURL", None)
    with args.plist.open("wb") as f:
        plistlib.dump(info, f, sort_keys=False)
    print("Personal connection release configured; users supply their own provider API key." if mode == "personal" else
          "Hosted service origin configured." if value else
          "No hosted deployment configured; free-service access remains unavailable.")


if __name__ == "__main__":
    main()

#!/bin/bash
# Build, run offline checks, and package. Never installs or launches the GUI.
# scripts/release.sh --check    read-only tools/certificate/notary readiness
# scripts/release.sh --local    universal development DMG (no Apple upload)
# scripts/release.sh --notarized universal signed/notarized manual-install DMG (uploads to Apple)
# scripts/release.sh --release  universal signed/notarized DMG (uploads to Apple)
# Set SKIP_BUILD=1 and BUILD_DIR to package an already tested build.
# Choose EXPERTISE_SERVICE_MODE=personal explicitly for an own-API-key release;
# otherwise a 1.1.9+ hosted release requires EXPERTISE_SERVICE_URL.
# SKIP_BUILD always checks the signed bundle's embedded flavor, not these env vars.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:---check}"
case "$MODE" in
  --check) exec "$ROOT/scripts/release-preflight.sh" ;;
  --local|--notarized|--release) ;;
  *) echo "usage: $0 [--check|--local|--notarized|--release]" >&2; exit 1 ;;
esac
VERSION="${VERSION:-$(cat "$ROOT/VERSION")}"
export VERSION
export BUILD_DIR="${BUILD_DIR:-$ROOT/build/distribution-$VERSION}"
export ARCHS="${ARCHS:-arm64 x86_64}"
if [[ "$MODE" != "--local" ]]; then
  if [[ "${SKIP_BUILD:-0}" == 1 ]]; then
    python3 "$ROOT/scripts/configure-hosted-service.py" --check-release-version "$VERSION" "$BUILD_DIR/Expertise Typer.app/Contents/Info.plist"
  else
    python3 "$ROOT/scripts/configure-hosted-service.py" --check-release-version "$VERSION"
  fi
  SIGN_IDENTITY="$("$ROOT/scripts/release-preflight.sh" --identity)"
  export SIGN_IDENTITY
  export NOTARY_PROFILE="${NOTARY_PROFILE:-FnDictate}"
  "$ROOT/scripts/release-preflight.sh"
else
  # --local deliberately does not use any real signing identity from the environment.
  export SIGN_IDENTITY=-
fi
if [[ "${SKIP_BUILD:-0}" != 1 ]]; then "$ROOT/scripts/build.sh"; fi
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILD_DIR/Expertise Typer.app/Contents/Info.plist")"
[[ "$BUILT_VERSION" == "$VERSION" ]] || { echo "error: app version $BUILT_VERSION differs from requested version $VERSION; rebuild first" >&2; exit 1; }
SKIP_BUILD=1 "$ROOT/scripts/test.sh"
"$ROOT/scripts/make-dmg.sh" "$MODE"

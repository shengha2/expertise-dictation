#!/bin/bash
# Package a tested app. --notarized and --release upload to Apple using real signing credentials.
# The final release filename is created only after notarization and Gatekeeper checks pass.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUILD="${BUILD_DIR:-$ROOT/build}"
DIST="${DIST_DIR:-$ROOT/dist}"
MODE="${1:---local}"
fail() { echo "error: $*" >&2; exit 1; }
[[ "$MODE" == "--local" || "$MODE" == "--notarized" || "$MODE" == "--release" ]] || fail "usage: $0 [--local|--notarized|--release]"
[[ -d "$BUILD/Expertise Typer.app" ]] || fail "build first: scripts/build.sh"
BUILD="$(cd "$BUILD" && pwd)"
SOURCE_APP="$BUILD/Expertise Typer.app"
codesign --verify --deep --strict --all-architectures "$SOURCE_APP"
INFO="$SOURCE_APP/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")" == com.hao.fndictate ]] || fail "unexpected bundle identifier; refusing to package another app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO")" == FnDictate ]] || fail "unexpected bundle executable"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$INFO")" == 'Expertise Typer' ]] || fail "unexpected product name; rebuild the renamed app first"
for usage_key in NSMicrophoneUsageDescription NSListenEventUsageDescription; do
  [[ -n "$(/usr/libexec/PlistBuddy -c "Print :$usage_key" "$INFO" 2>/dev/null || true)" ]] || fail "missing $usage_key permission explanation"
done
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+([.][0-9]+)*$ ]] || fail "version must be dotted numbers"
if [[ "$MODE" != "--local" ]]; then
  python3 "$ROOT/scripts/configure-hosted-service.py" --check-release-version "$VERSION" "$INFO"
fi
SERVICE_MODE="$(/usr/libexec/PlistBuddy -c 'Print :ExpertiseServiceMode' "$INFO" 2>/dev/null || printf legacy)"
case "$SERVICE_MODE" in
  personal)
    CONNECTION_NOTE="This is the personal-connection release. Add your own provider API key in
   Preferences > More options > Connection before practice. Existing saved keys
   are retained. Provider charges apply; the free hosted service is not included."
    ;;
  hosted)
    CONNECTION_NOTE="This hosted build needs an available operator service; see MINT.md for
   availability and the optional personal API-key connection."
    ;;
  legacy)
    CONNECTION_NOTE="This earlier build uses its existing connection settings. See MINT.md
   and Preferences for your provider connection and setup requirements."
    ;;
  *) fail "unknown embedded service mode; rebuild with personal or hosted" ;;
esac
DOCUMENTATION="$(python3 "$ROOT/scripts/public_documents.py")"
mkdir -p "$DIST"
DIST="$(cd "$DIST" && pwd)"
NAME="Expertise-Typer-$VERSION"
[[ "$MODE" == "--local" ]] && NAME="$NAME-local"
[[ "$MODE" == "--notarized" ]] && NAME="$NAME-notarized-manual"
DMG="$DIST/$NAME.dmg"
LOCK="$DIST/.$NAME.package-lock"
mkdir "$LOCK" 2>/dev/null || fail "packaging is already running for $NAME (lock: $LOCK)"
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
[[ ! -e "$DMG" && ! -e "$DMG.sha256" && ! -e "$DIST/$NAME-release.txt" ]] || fail "output already exists for $NAME. Use a new version or a different DIST_DIR; existing artifacts were preserved."

if [[ "$MODE" == "--release" ]]; then
  python3 "$ROOT/scripts/update-config.py" --require "$INFO"
elif [[ "$MODE" == "--notarized" ]]; then
  # This mode is explicitly for manual installs. Never hide partial or configured
  # update settings behind its "automatic updates unavailable" label.
  python3 "$ROOT/scripts/update-config.py" "$INFO"
  python3 - "$INFO" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "rb") as source:
    info = plistlib.load(source)
if any(key in info for key in ("SUFeedURL", "SUPublicEDKey")):
    sys.exit("error: --notarized requires SUFeedURL and SUPublicEDKey to be absent; use --release for a configured updater")
for key in ("SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed"):
    if info.get(key) is not True:
        sys.exit("error: " + key + " must remain enabled")
PY
fi
if [[ "$MODE" != "--local" ]]; then
  python3 "$ROOT/scripts/verify-release-app.py" "$SOURCE_APP"
  export NOTARY_PROFILE="${NOTARY_PROFILE:-FnDictate}"
  SIGN_IDENTITY="$("$ROOT/scripts/release-preflight.sh" --identity)"
  export SIGN_IDENTITY
  "$ROOT/scripts/release-preflight.sh"
  SIGNATURE="$(codesign -dv --verbose=4 "$SOURCE_APP" 2>&1)"
  [[ "$SIGNATURE" == *"Authority=Developer ID Application:"* && "$SIGNATURE" == *"(runtime)"* && "$SIGNATURE" == *"Timestamp="* ]] || fail "rebuild with a Developer ID Application identity, hardened runtime, and secure timestamp first"
fi

STAGE="$(mktemp -d "$DIST/.expertise-dictation-package.XXXXXX")"
trap 'rm -rf "$STAGE"; rmdir "$LOCK" 2>/dev/null || true' EXIT
mkdir -p "$STAGE/image"
APP="$STAGE/image/Expertise Typer.app"
ditto "$SOURCE_APP" "$APP"

notarize() {
  local artifact="$1" label="$2" request_id status
  local result="$LOGS/$label-result.json"
  echo "Submitting $label to Apple; result log: $result"
  if ! xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" --wait --timeout "${NOTARY_TIMEOUT:-20m}" --output-format json > "$result"; then
    echo "error: notarization failed or exceeded the wait timeout. Inspect $result before retrying." >&2
    return 1
  fi
  request_id="$(plutil -extract id raw -o - "$result")"
  status="$(plutil -extract status raw -o - "$result")"
  xcrun notarytool log "$request_id" "$LOGS/$label-log.json" --keychain-profile "$NOTARY_PROFILE" >/dev/null || true
  [[ "$status" == Accepted ]] || { echo "error: Apple returned $status; see $LOGS/$label-log.json" >&2; return 1; }
  printf '%s\n' "$request_id" > "$LOGS/$label-id.txt"
}

if [[ "$MODE" != "--local" ]]; then
  codesign -d --entitlements - --xml "$APP" > "$STAGE/entitlements.plist" 2>/dev/null
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$STAGE/entitlements.plist" 2>/dev/null || true)" == true ]] || fail "signed app needs the Audio Input entitlement"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$STAGE/entitlements.plist" 2>/dev/null || true)" != true ]] || fail "release must not enable get-task-allow"
  # This app requires only Audio Input. Unexpected exceptions must be reviewed,
  # rather than silently shipping JIT, debugger, or library-validation access.
  [[ "$(plutil -convert json -o - "$STAGE/entitlements.plist")" == '{"com.apple.security.device.audio-input":true}' ]] || fail "unexpected release entitlements; expected Audio Input only"
  LOGS="$DIST/notary/$NAME-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p "$LOGS"
  ditto -c -k --keepParent "$APP" "$STAGE/Expertise-Typer.zip"
  notarize "$STAGE/Expertise-Typer.zip" app
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  codesign --verify --deep --strict --all-architectures "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
  STATUS="Developer ID signed and Apple notarized"
  INSTALL_NOTE="This release is signed with Developer ID and notarized by Apple."
  if [[ "$MODE" == "--notarized" ]]; then
    STATUS="$STATUS; manual installation; automatic updates unavailable"
    INSTALL_NOTE="$INSTALL_NOTE
Automatic updates are unavailable in this manual-install build. Install a later
configured release manually to enable its update service."
  fi
else
  STATUS="Local development build; NOT Apple notarized"
  INSTALL_NOTE="This is a LOCAL DEVELOPMENT build, not an Apple-notarized release.
If macOS blocks a downloaded copy, proceed only if you trust the source: attempt to
open it, then use System Settings > Privacy & Security > Open Anyway if offered.
For your own Mac, scripts/install-local.sh builds and installs from source.
Local ad-hoc rebuilds can require permission grants again."
fi

ln -s /Applications "$STAGE/image/Applications"
GUIDE="$STAGE/image/Guide and licenses"
mkdir -p "$GUIDE"
while IFS= read -r document; do
  mkdir -p "$GUIDE/$(dirname "$document")"
  cp "$ROOT/$document" "$GUIDE/$document"
done <<< "$DOCUMENTATION"
# Include only explicitly reviewed evidence, never an entire diagnostics folder.
# Paths in this optional allowlist are relative to docs/ (for example,
# evidence/1.1.0/bilingual-smoke-validation.json).
if [[ -f "$ROOT/docs/distribution-evidence.txt" ]]; then
  while IFS= read -r evidence || [[ -n "$evidence" ]]; do
    [[ -z "$evidence" || "$evidence" == \#* ]] && continue
    [[ "$evidence" =~ ^evidence/[A-Za-z0-9_./-]+$ && "$evidence" != *..* ]] || fail "unsafe evidence path in docs/distribution-evidence.txt"
    [[ -f "$ROOT/docs/$evidence" && ! -L "$ROOT/docs/$evidence" ]] || fail "missing or linked evidence file: $evidence"
    mkdir -p "$GUIDE/docs/$(dirname "$evidence")"
    cp "$ROOT/docs/$evidence" "$GUIDE/docs/$evidence"
  done < "$ROOT/docs/distribution-evidence.txt"
fi
cat > "$GUIDE/Read me first.txt" <<TXT
Expertise Typer $VERSION

INSTALL
1. Quit Expertise Typer, Expertise Dictation, or FnDictate if it is running.
2. Drag Expertise Typer into Applications, then open that exact copy.
   If upgrading from Expertise Dictation or FnDictate, keep the old app closed
   and move its app bundle aside after the new copy works. Your dictionary,
   settings, keys and history use the same profile and stay available.
$INSTALL_NOTE
3. Follow the app's guided permissions, microphone, shortcut, and practice checks.
   $CONNECTION_NOTE
4. Read MINT.md for the shortcut, dictation workflow, and troubleshooting.

Do not disable Gatekeeper or remove quarantine attributes to install this app.
TXT
CANDIDATE="$STAGE/$NAME.dmg"
"$ROOT/scripts/create-installer-image.sh" "$STAGE/image" "$CANDIDATE" "$VERSION"
if [[ "$MODE" != "--local" ]]; then
  codesign --timestamp --sign "$SIGN_IDENTITY" "$CANDIDATE"
  codesign --verify --strict "$CANDIDATE"
  notarize "$CANDIDATE" dmg
  xcrun stapler staple "$CANDIDATE"
  xcrun stapler validate "$CANDIDATE"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$CANDIDATE"
fi
hdiutil verify "$CANDIDATE" >/dev/null
HASH="$(shasum -a 256 "$CANDIDATE" | awk '{print $1}')"
printf '%s  %s\n' "$HASH" "$NAME.dmg" > "$STAGE/$NAME.dmg.sha256"
cat > "$STAGE/$NAME-release.txt" <<TXT
Expertise Typer $VERSION
Status: $STATUS
Service mode: $SERVICE_MODE
Created (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)
Architectures: $(lipo -archs "$APP/Contents/MacOS/FnDictate")
Bundle identifier: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
SHA-256: $HASH
Usage guide: Guide and licenses/MINT.md (included in the disk image)
Documentation (included in the disk image):
$DOCUMENTATION
TXT
if [[ "$MODE" != "--local" ]]; then
  printf 'App notarization: %s\nDMG notarization: %s\n' "$(cat "$LOGS/app-id.txt")" "$(cat "$LOGS/dmg-id.txt")" >> "$STAGE/$NAME-release.txt"
fi
mv "$CANDIDATE" "$DMG"
mv "$STAGE/$NAME.dmg.sha256" "$DMG.sha256"
mv "$STAGE/$NAME-release.txt" "$DIST/$NAME-release.txt"
echo "Packaged $DMG"
echo "Status: $STATUS"
echo "Checksum: $DMG.sha256"

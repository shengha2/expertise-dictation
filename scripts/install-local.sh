#!/bin/bash
# Build and install Expertise Dictation, migrating an older FnDictate bundle.
# The executable, bundle identifier, and user-data directory retain their old names.
# Set INSTALL_DIR to choose a location; SKIP_BUILD=1 installs a pretested build.
# Does not launch the app or modify microphone/Accessibility/security settings.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${BUILD_DIR:-$ROOT/build}"
APP="$BUILD/Expertise Dictation.app"
die() { echo "error: $*" >&2; exit 1; }
running() { pgrep -x FnDictate >/dev/null; }
validate_bundle() {
  local bundle="$1"
  [[ ! -L "$bundle" ]] || die "refusing a symbolic-link app bundle at $bundle"
  [[ -d "$bundle" ]] || die "app bundle missing: $bundle"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist" 2>/dev/null || true)" == com.hao.fndictate ]] || die "unexpected bundle identifier at $bundle"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Contents/Info.plist" 2>/dev/null || true)" == FnDictate ]] || die "unexpected executable at $bundle"
}

running && die "Quit Expertise Dictation or FnDictate using its menu before installing. Your current session has not been changed."
if [[ -z "${INSTALL_DIR:-}" ]]; then
  system_copy=0
  user_copy=0
  for name in 'Expertise Dictation.app' FnDictate.app; do
    [[ ! -e "/Applications/$name" && ! -L "/Applications/$name" ]] || system_copy=1
    [[ ! -e "$HOME/Applications/$name" && ! -L "$HOME/Applications/$name" ]] || user_copy=1
  done
  if [[ "$system_copy" == 1 && "$user_copy" == 1 ]]; then
    die "Copies exist in /Applications and ~/Applications. Choose INSTALL_DIR and keep other copies closed until the upgrade is verified."
  elif [[ "$system_copy" == 1 ]]; then
    INSTALL_DIR=/Applications
  else
    INSTALL_DIR="$HOME/Applications"
  fi
fi
mkdir -p "$INSTALL_DIR"
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"
[[ -w "$INSTALL_DIR" ]] || die "$INSTALL_DIR is not writable; use a directory owned by your user."
DEST="$INSTALL_DIR/Expertise Dictation.app"
LEGACY="$INSTALL_DIR/FnDictate.app"
for installed in "$DEST" "$LEGACY"; do
  if [[ -e "$installed" || -L "$installed" ]]; then validate_bundle "$installed"; fi
done
if [[ "${SKIP_BUILD:-0}" != 1 ]]; then
  ARCHS="${ARCHS:-$(uname -m)}" BUILD_DIR="$BUILD" "$ROOT/scripts/build.sh"
fi
validate_bundle "$APP"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Contents/Info.plist")" == 'Expertise Dictation' ]] || die "build the renamed Expertise Dictation app first"
SOURCE="$(cd "$APP" && pwd)"
[[ "$SOURCE" != "$DEST" && "$SOURCE" != "$LEGACY" ]] || die "build and install locations must differ"
codesign --verify --deep --strict --all-architectures "$APP"
"$APP/Contents/MacOS/FnDictate" --selftest
running && die "The app started during validation. Quit it and retry with SKIP_BUILD=1."

LOCK="$INSTALL_DIR/.Expertise-Dictation-install.lock"
mkdir "$LOCK" 2>/dev/null || die "another installation is running (lock: $LOCK)"
STAGE=""
COMMITTED=0
PLACED=0
cleanup() {
  local result=$? rollback_failed=0
  trap - EXIT
  if [[ -n "$STAGE" && "$COMMITTED" != 1 ]]; then
    if [[ "$PLACED" == 1 && -d "$DEST" ]]; then rm -rf "$DEST" || rollback_failed=1; fi
    if [[ -d "$STAGE/previous-branded.app" ]]; then
      if [[ ! -e "$DEST" ]]; then mv "$STAGE/previous-branded.app" "$DEST" || rollback_failed=1; else rollback_failed=1; fi
    fi
    if [[ -d "$STAGE/previous-legacy.app" ]]; then
      if [[ ! -e "$LEGACY" ]]; then mv "$STAGE/previous-legacy.app" "$LEGACY" || rollback_failed=1; else rollback_failed=1; fi
    fi
  fi
  if [[ "$rollback_failed" == 1 ]]; then
    echo "error: automatic rollback could not complete; previous apps are preserved at $STAGE and in Backups" >&2
    result=1
  elif [[ -n "$STAGE" ]]; then
    rm -rf "$STAGE"
  fi
  rmdir "$LOCK" 2>/dev/null || true
  exit "$result"
}
trap cleanup EXIT
STAGE="$(mktemp -d "$INSTALL_DIR/.Expertise-Dictation-install.XXXXXX")"
ditto "$APP" "$STAGE/Expertise Dictation.app"
codesign --verify --deep --strict --all-architectures "$STAGE/Expertise Dictation.app"

# Back up every displaced bundle before moving either one. User data stays put.
BACKUPS="${BACKUP_DIR:-$HOME/Library/Application Support/FnDictate/Backups}"
for installed in "$DEST" "$LEGACY"; do
  if [[ -d "$installed" ]]; then
    mkdir -p "$BACKUPS"
    label="$(basename "$installed" .app)"
    BACKUP="$BACKUPS/${label// /-}-$(date +%Y%m%d-%H%M%S)-$$.zip"
    ditto -c -k --keepParent "$installed" "$BACKUP"
    unzip -tq "$BACKUP" >/dev/null
    echo "Previous installation backed up to $BACKUP"
  fi
done
running && die "The app restarted while backing up. Quit it before retrying; installed copies were preserved."
[[ ! -d "$DEST" ]] || mv "$DEST" "$STAGE/previous-branded.app"
[[ ! -d "$LEGACY" ]] || mv "$LEGACY" "$STAGE/previous-legacy.app"
mv "$STAGE/Expertise Dictation.app" "$DEST"
PLACED=1
codesign --verify --deep --strict --all-architectures "$DEST"
COMMITTED=1
echo "Installed $DEST"
if [[ -d "$STAGE/previous-legacy.app" ]]; then
  echo "The older FnDictate app was migrated. Settings, keys, history, and recovery data remain in their existing locations."
fi
echo "Open this exact copy, then check Setup for Microphone and Accessibility permissions."
echo "Ad-hoc rebuilds can require renewed permissions; this installer does not alter security settings."

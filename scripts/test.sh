#!/bin/bash
# Offline checks only. Does not launch the GUI, capture audio, or use saved keys.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${BUILD_DIR:-$ROOT/build}"
APP="$BUILD/Expertise Dictation.app"
for script in "$ROOT"/scripts/*.sh; do bash -n "$script"; done
plutil -lint "$ROOT/Resources/Info.plist" "$ROOT/Resources/FnDictate.entitlements"
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  ARCHS="${ARCHS:-$(uname -m)}" BUILD_DIR="$BUILD" "$ROOT/scripts/build.sh"
fi
[[ -x "$APP/Contents/MacOS/FnDictate" ]] || { echo "error: app missing; build first" >&2; exit 1; }
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict --all-architectures "$APP"
"$APP/Contents/MacOS/FnDictate" --selftest
echo "Offline checks passed. Microphone, hotkey permissions, text insertion, and provider calls require an interactive test."

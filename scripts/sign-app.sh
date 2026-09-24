#!/bin/bash
# Sign nested Sparkle code inside-out; never use --deep for signing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?usage: sign-app.sh APP [IDENTITY]}"
IDENTITY="${2:--}"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
BASE="$FRAMEWORK/Versions/B"
SIGN_OPTIONS=(--force --sign "$IDENTITY" --options runtime)
[[ "$IDENTITY" == - ]] || SIGN_OPTIONS+=(--timestamp)
for helper in "$BASE/XPCServices/Installer.xpc" "$BASE/Autoupdate" "$BASE/Updater.app"; do
  [[ -e "$helper" ]] || { echo "error: missing Sparkle helper $helper" >&2; exit 1; }
  codesign "${SIGN_OPTIONS[@]}" "$helper"
done
codesign "${SIGN_OPTIONS[@]}" \
  --preserve-metadata=entitlements "$BASE/XPCServices/Downloader.xpc"
codesign "${SIGN_OPTIONS[@]}" "$FRAMEWORK"
if [[ "$IDENTITY" == - ]]; then
  codesign --force --sign - --identifier com.hao.fndictate "$APP"
  echo 'note: local ad-hoc build; not notarized. Rebuilds may require renewed permission grants.'
else
  codesign --force --sign "$IDENTITY" --options runtime --timestamp \
    --entitlements "$ROOT/Resources/FnDictate.entitlements" --identifier com.hao.fndictate "$APP"
fi
codesign --verify --deep --strict --all-architectures --verbose=1 "$APP"

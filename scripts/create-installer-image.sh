#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# == 3 ]] || { echo 'usage: create-installer-image source output version' >&2; exit 2; }
SOURCE="$1"
OUTPUT="$2"
PRODUCT_VERSION="$3"
ICON="$SOURCE/Expertise Typer.app/Contents/Resources/AppIcon.icns"
[[ -s "$ICON" ]] || { echo 'error: branded app icon is missing' >&2; exit 1; }
[[ -d "$SOURCE/Guide and licenses" ]] || { echo 'error: installer guide is missing' >&2; exit 1; }
ASSETS="$(mktemp -d "${TMPDIR:-/tmp}/expertise-installer-assets.XXXXXX")"
trap 'rm -rf "$ASSETS"' EXIT
clang -fobjc-arc -fmodules -framework AppKit "$ROOT/scripts/render-installer.m" -o "$ASSETS/render-installer"
"$ASSETS/render-installer" "$ASSETS/background.png"
"$ASSETS/render-installer" "$ASSETS/background@2x.png" 2
DMG_PYTHON="$("$ROOT/scripts/fetch-dmg-tools.sh")"
"$DMG_PYTHON" "$ROOT/scripts/build-branded-dmg.py" --source "$SOURCE" --output "$OUTPUT" \
  --volume "Expertise Typer $PRODUCT_VERSION" --icon "$ICON" --background "$ASSETS/background.png"

#!/bin/bash
# Pinned upstream distribution. Only the verified archive is extracted or executed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=2.10.0
SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
CACHE="${SPARKLE_CACHE_DIR:-$ROOT/build/vendor}"
mkdir -p "$CACHE"
CACHE="$(cd "$CACHE" && pwd)"
ARCHIVE="$CACHE/Sparkle-$VERSION.tar.xz"
DEST="$CACHE/Sparkle-$VERSION"
LOCK="$CACHE/.sparkle-$VERSION.lock"
mkdir "$LOCK" 2>/dev/null || { echo 'error: another Sparkle fetch is running' >&2; exit 1; }
TMP=""
trap '[[ -z "$TMP" ]] || rm -rf "$TMP"; rmdir "$LOCK" 2>/dev/null || true' EXIT
if [[ ! -f "$ARCHIVE" ]]; then
  TMP="$(mktemp -d "$CACHE/.sparkle-download.XXXXXX")"
  curl --fail --location --proto '=https' --tlsv1.2 --retry 2 --max-time 180 \
    "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" \
    --output "$TMP/Sparkle.tar.xz" >&2
  [[ "$(shasum -a 256 "$TMP/Sparkle.tar.xz" | awk '{print $1}')" == "$SHA256" ]] || { echo 'error: Sparkle download checksum mismatch' >&2; exit 1; }
  mv "$TMP/Sparkle.tar.xz" "$ARCHIVE"
  rm -rf "$TMP"
  TMP=""
fi
[[ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" == "$SHA256" ]] || { echo 'error: cached Sparkle checksum mismatch; existing archive preserved' >&2; exit 1; }
TMP="$(mktemp -d "$CACHE/.sparkle-extract.XXXXXX")"
tar -xJf "$ARCHIVE" -C "$TMP"
[[ -d "$TMP/Sparkle.framework" && -x "$TMP/bin/generate_appcast" && -x "$TMP/bin/sign_update" ]] || { echo 'error: unexpected Sparkle archive layout' >&2; exit 1; }
# Refresh from the pinned archive so a modified extracted cache is never reused.
rm -rf "$DEST"
mv "$TMP" "$DEST"
TMP=""
printf '%s\n' "$DEST"

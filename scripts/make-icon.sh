#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/build"
SDK="${SDKROOT:-$(xcrun --show-sdk-path 2>/dev/null || echo /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk)}"
clang -fobjc-arc -fmodules -fmodules-cache-path="$ROOT/build/clang-modcache" -isysroot "$SDK" -framework AppKit "$ROOT/scripts/make-icon.m" -o "$ROOT/build/make-icon"
"$ROOT/build/make-icon" "$ROOT/Resources/AppIcon.icns" "$ROOT/Resources/Brand/ExpertiseTyper.png"

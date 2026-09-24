#!/bin/bash
# Builds Expertise Typer.app with the plain Swift compiler (no Xcode needed).
#
#   scripts/build.sh            release build, arm64 + x86_64 universal binary
#   ARCHS=arm64 scripts/build.sh    faster single-architecture build
#   DEBUG=1 scripts/build.sh    -Onone build
#   EXPERTISE_SERVICE_MODE=personal scripts/build.sh  explicit own-API-key flavor
# Hosted is the default flavor and needs EXPERTISE_SERVICE_URL for distribution.
#
# Output: build/Expertise Typer.app (internal executable remains FnDictate).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
python3 "$ROOT/scripts/generate-prompts.py" --check

VERSION="${VERSION:-$(cat VERSION 2>/dev/null || echo 1.0.0)}"
BUILD_NUMBER="$(python3 "$ROOT/scripts/update-config.py" --build-version "$VERSION")"
ARCHS="${ARCHS:-arm64 x86_64}"
MIN_OS="14.0"
BUILD="${BUILD_DIR:-$ROOT/build}"
APP="$BUILD/Expertise Typer.app"
mkdir -p "$BUILD"
BUILD="$(cd "$BUILD" && pwd)"
APP="$BUILD/Expertise Typer.app"
[[ "$(uname -s)" == "Darwin" ]] || { echo "error: building requires macOS" >&2; exit 1; }
SWIFTC="$(xcrun --find swiftc)"
SPARKLE="$("$ROOT/scripts/fetch-sparkle.sh")"

# --- Locate SDK -------------------------------------------------------------
SDK="${SDKROOT:-}"
if [[ -z "$SDK" ]]; then
  SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"
fi
if [[ -z "$SDK" || ! -d "$SDK" ]]; then
  SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
fi
[[ -d "$SDK" ]] || { echo "error: macOS SDK missing; run xcode-select --install" >&2; exit 1; }
echo "SDK: $SDK"

# --- Work around stale Command Line Tools installs -------------------------
# Some CLT installs carry a leftover usr/include/swift/module.modulemap next to
# bridging.modulemap, both defining the SwiftBridging module, which makes every
# swiftc invocation fail with "redefinition of module 'SwiftBridging'". A VFS
# overlay hides the stale copy without touching the system directory.
# Keep this array nonempty: macOS Bash 3 treats an empty array as unset under -u.
EXTRA_FLAGS=(-swift-version 5)
TOOLCHAIN_INC="$(dirname "$(dirname "$SWIFTC")")/include/swift"
[[ -d "$TOOLCHAIN_INC" ]] || TOOLCHAIN_INC="/Library/Developer/CommandLineTools/usr/include/swift"
if [[ -f "$TOOLCHAIN_INC/module.modulemap" && -f "$TOOLCHAIN_INC/bridging.modulemap" ]]; then
  : > "$BUILD/empty.modulemap"
  cat > "$BUILD/overlay.yaml" <<YAML
{ "version": 0, "case-sensitive": "false",
  "roots": [ { "name": "$TOOLCHAIN_INC", "type": "directory",
    "contents": [ { "name": "module.modulemap", "type": "file", "external-contents": "$BUILD/empty.modulemap" } ] } ] }
YAML
  EXTRA_FLAGS+=(-vfsoverlay "$BUILD/overlay.yaml")
  echo "note: applying modulemap overlay workaround for this toolchain"
fi

OPT=(-O)
[[ "${DEBUG:-0}" == "1" ]] && OPT=(-Onone -g)

SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find Sources/FnDictate -name '*.swift' | sort)

FRAMEWORKS=(-framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreAudio -framework ServiceManagement -framework ApplicationServices -framework Carbon -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks)

# --- Compile one slice per architecture ------------------------------------
SLICES=()
for ARCH in $ARCHS; do
  [[ "$ARCH" == "arm64" || "$ARCH" == "x86_64" ]] || { echo "error: unsupported architecture $ARCH" >&2; exit 1; }
  OUT="$BUILD/FnDictate-$ARCH"
  echo "compiling $ARCH ..."
  "$SWIFTC" "${OPT[@]}" \
    -target "$ARCH-apple-macos$MIN_OS" -sdk "$SDK" \
    -module-cache-path "$BUILD/modcache-$ARCH" \
    "${EXTRA_FLAGS[@]}" \
    -module-name FnDictate \
    "${SOURCES[@]}" "${FRAMEWORKS[@]}" \
    -o "$OUT"
  SLICES+=("$OUT")
done

# --- Assemble the bundle ---------------------------------------------------
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$SPARKLE/LICENSE" "$APP/Contents/Resources/LICENSE-Sparkle.txt"
if [[ ${#SLICES[@]} -gt 1 ]]; then
  lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/FnDictate"
else
  cp "${SLICES[0]}" "$APP/Contents/MacOS/FnDictate"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
python3 "$ROOT/scripts/update-config.py" --configure "$APP/Contents/Info.plist"
python3 "$ROOT/scripts/configure-hosted-service.py" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp -R Resources/Sounds "$APP/Contents/Resources/"
cp -R Resources/Fonts "$APP/Contents/Resources/"
cp -R prompts "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE-Expertise-Typer.txt"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  echo "warning: Resources/AppIcon.icns missing (run scripts/make-icon.sh)"
fi

# --- Sign ------------------------------------------------------------------
# Ad-hoc signing is for local development only. Let codesign derive a genuine
# code requirement; an identifier alone must not stand in for a signer identity.
# A Developer ID build also needs Audio Input under the hardened runtime.
"$ROOT/scripts/sign-app.sh" "$APP" "${SIGN_IDENTITY:--}"
codesign --verify --deep --strict --all-architectures --verbose=1 "$APP" 2>&1 | sed 's/^/codesign: /'
echo "built $APP ($VERSION build $BUILD_NUMBER, archs: $ARCHS)"

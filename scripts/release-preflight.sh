#!/bin/bash
# Read-only release readiness. Prints certificate identity metadata, never credentials.
# Set NOTARY_PROFILE (defaults to FnDictate) and SIGN_IDENTITY (optional if one ID exists).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:---check}"
[[ "$MODE" == "--check" || "$MODE" == "--identity" ]] || { echo "usage: $0 [--check|--identity]" >&2; exit 1; }
fail() { echo "error: $*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || fail "release packaging requires macOS"
for tool in swiftc notarytool stapler; do
  xcrun --find "$tool" >/dev/null || fail "Apple $tool is unavailable; install/update Command Line Tools"
done

MATCHES=()
IDENTITIES=()
while IFS= read -r line; do
  if [[ "$line" =~ ([0-9A-Fa-f]{40})\ \"(Developer\ ID\ Application:\ [^\"]+)\" ]]; then
    fingerprint="${BASH_REMATCH[1]}"
    identity="${BASH_REMATCH[2]}"
    IDENTITIES+=("$identity")
    if [[ -z "${SIGN_IDENTITY:-}" || "$SIGN_IDENTITY" == "$identity" || "$SIGN_IDENTITY" == "$fingerprint" ]]; then
      MATCHES+=("$identity")
    fi
  fi
done < <(security find-identity -v -p codesigning)
[[ ${#IDENTITIES[@]} -gt 0 ]] || fail "no valid Developer ID Application signing identity is installed. Install a Developer ID Application identity with its private key before distributing this app."
[[ ${#MATCHES[@]} -gt 0 ]] || fail "SIGN_IDENTITY does not match an available Developer ID Application identity"
[[ ${#MATCHES[@]} -eq 1 ]] || fail "multiple Developer ID Application identities found; set SIGN_IDENTITY to the exact identity or SHA-1 fingerprint"
IDENTITY="${MATCHES[0]}"
if [[ "$MODE" == "--identity" ]]; then printf '%s\n' "$IDENTITY"; exit 0; fi

echo "Signing identity: $IDENTITY"
PROFILE="${NOTARY_PROFILE:-FnDictate}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/fndictate-notary-check.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
if ! xcrun notarytool history --keychain-profile "$PROFILE" --output-format json > "$TMP/history.json" 2> "$TMP/error.txt"; then
  cat "$TMP/error.txt" >&2
  fail "notarization profile '$PROFILE' is unavailable or cannot authenticate. Configure it interactively with xcrun notarytool store-credentials, then retry."
fi
echo "Notarization profile: $PROFILE (authenticated)"
echo "Release tools and credentials are ready. No build, upload, install, or account changes were performed."

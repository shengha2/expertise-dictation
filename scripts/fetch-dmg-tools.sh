#!/bin/bash
# Isolated, hash-pinned build dependencies; never modifies the system Python.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$ROOT/build/vendor/dmg-tools"
REQUIREMENTS="$ROOT/scripts/requirements-dmg.txt"
FINGERPRINT="$(shasum -a 256 "$REQUIREMENTS" | awk '{print $1}')"
if [[ ! -x "$RUNTIME/bin/python3" || ! -f "$RUNTIME/requirements.sha256" || "$(cat "$RUNTIME/requirements.sha256")" != "$FINGERPRINT" ]]; then
  python3 -m venv "$RUNTIME"
  "$RUNTIME/bin/python3" -m pip install --disable-pip-version-check --only-binary=:all: --require-hashes -r "$REQUIREMENTS" >&2
  printf '%s\n' "$FINGERPRINT" > "$RUNTIME/requirements.sha256"
fi
printf '%s\n' "$RUNTIME/bin/python3"

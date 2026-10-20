#!/usr/bin/env bash
set -euo pipefail

# Writes dist/checksums.txt for the current dist/YappYapp.dmg and a fresh
# dist/YappYapp.app.zip. YA-76: run it after anything that rewrites the DMG
# or the app (verify_release.sh, notarize.sh), so the published checksums
# always describe the files on disk.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${YAPPYAPP_DIST_DIR:-$ROOT_DIR/dist}"
CHECKSUMS_PATH="$DIST_DIR/checksums.txt"

rm -f "$CHECKSUMS_PATH"
(
  cd "$DIST_DIR"
  if [[ -d "YappYapp.app" ]]; then
    rm -f "YappYapp.app.zip"
    ditto -c -k --keepParent "YappYapp.app" "YappYapp.app.zip"
  fi

  for artifact in "YappYapp.dmg" "YappYapp.app.zip"; do
    if [[ -f "$artifact" ]]; then
      shasum -a 256 "$artifact"
    fi
  done
) > "$CHECKSUMS_PATH"

(cd "$DIST_DIR" && shasum -a 256 -c "$(basename "$CHECKSUMS_PATH")" >/dev/null)
cat "$CHECKSUMS_PATH"

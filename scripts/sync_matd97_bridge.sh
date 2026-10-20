#!/usr/bin/env bash
set -euo pipefail

# YA-07: keeps matd97-bridge/ identical to what was just published.
#
# 0.3.x installs poll the old feed
#   https://raw.githubusercontent.com/matd97/yappyapp-releases/main/appcast.xml
# and older Homebrew installs use matd97/tap. Both resolve today only through
# GitHub's rename redirect to migueltorrezd. matd97-bridge/ holds the exact
# appcast and cask those clients must see, ready to publish under the old
# name if the redirect lapses (see docs/PACKAGING.md, "The matd97 bridge").
#
# Usage:
#   ./scripts/sync_matd97_bridge.sh <published-appcast.xml> <cask.rb>
#       copy both files into matd97-bridge/
#   ./scripts/sync_matd97_bridge.sh --check <published-appcast.xml> [<cask.rb>]
#       fail when matd97-bridge/ differs from them

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_DIR="${YAPPYAPP_BRIDGE_DIR:-$ROOT_DIR/matd97-bridge}"
BRIDGE_APPCAST="$BRIDGE_DIR/appcast.xml"
BRIDGE_CASK="$BRIDGE_DIR/Casks/yappyapp.rb"

fail() {
  echo "FAIL $*" >&2
  exit 1
}

# The bridge must never send anyone to a matd97 download URL.
check_owner() {
  local file="$1"
  if grep -nE "matd97([^-]|$)" "$file" | grep -v "untap" >/dev/null; then
    fail "$file still points at matd97"
  fi
}

check_mode=0
if [[ "${1:-}" == "--check" ]]; then
  check_mode=1
  shift
fi

APPCAST="${1:?usage: sync_matd97_bridge.sh [--check] <published-appcast.xml> <cask.rb>}"
CASK="${2:-}"
[[ -s "$APPCAST" ]] || fail "appcast missing or empty: $APPCAST"
if [[ $check_mode -eq 0 && -z "$CASK" ]]; then
  fail "usage: sync_matd97_bridge.sh <published-appcast.xml> <cask.rb>"
fi
if [[ -n "$CASK" ]]; then
  [[ -s "$CASK" ]] || fail "cask missing or empty: $CASK"
  check_owner "$CASK"
fi
check_owner "$APPCAST"

if [[ $check_mode -eq 1 ]]; then
  cmp -s "$APPCAST" "$BRIDGE_APPCAST" || fail "matd97-bridge/appcast.xml differs from $APPCAST"
  if [[ -n "$CASK" ]]; then
    cmp -s "$CASK" "$BRIDGE_CASK" || fail "matd97-bridge/Casks/yappyapp.rb differs from $CASK"
  fi
  echo "OK   matd97-bridge matches the published feed"
  exit 0
fi

mkdir -p "$BRIDGE_DIR/Casks"
cp "$APPCAST" "$BRIDGE_APPCAST"
cp "$CASK" "$BRIDGE_CASK"
echo "Synced matd97-bridge/ from $APPCAST and $CASK"

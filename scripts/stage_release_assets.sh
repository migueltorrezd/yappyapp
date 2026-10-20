#!/usr/bin/env bash
set -euo pipefail

# Stages the final upload set for one release from dist/YappYapp.dmg:
#
#   dist/release-<version>/YappYapp-<version>.dmg   versioned asset (appcast, cask)
#   dist/release-<version>/YappYapp.dmg             evergreen asset (website link)
#   dist/release-<version>/checksums.txt            SHA-256 of both, identical
#   dist/release-<version>/checksum-line.md         line pasted into release notes
#   dist/release-<version>/yappyapp.rb              cask with version and sha256
#
# YA-76 and YA-09: both DMGs are byte copies of one file, and every published
# checksum is computed from the staged asset, never typed by hand.
#
# Usage:
#   ./scripts/stage_release_assets.sh            stage from dist/YappYapp.dmg
#   ./scripts/stage_release_assets.sh --check DIR
#       verify an existing staging folder: checksums match the files on disk,
#       the versioned and evergreen DMGs are identical, and the cask carries
#       the same sha256.
#
# Overrides: YAPPYAPP_DIST_DIR (default dist), YAPPYAPP_RELEASE_VERSION
# (default app.short_version in docs/RELEASE_PROVENANCE.json).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${YAPPYAPP_DIST_DIR:-$ROOT_DIR/dist}"
PROVENANCE="$ROOT_DIR/docs/RELEASE_PROVENANCE.json"
CASK_TEMPLATE="$ROOT_DIR/packaging/homebrew/yappyapp.rb"

fail() {
  echo "FAIL $*" >&2
  exit 1
}

sha256_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

# Writes the cask template with version and sha256 filled in.
render_cask() {
  local version="$1" sha="$2" out="$3"
  sed \
    -e "s/^  version \".*\"$/  version \"$version\"/" \
    -e "s/^  sha256 \".*\"$/  sha256 \"$sha\"/" \
    "$CASK_TEMPLATE" > "$out"
  grep -q "^  version \"$version\"$" "$out" || fail "cask version was not filled in"
  grep -q "^  sha256 \"$sha\"$" "$out" || fail "cask sha256 was not filled in"
}

check_staging() {
  local dir="$1"
  [[ -d "$dir" ]] || fail "staging folder missing: $dir"
  local versioned
  versioned="$(find "$dir" -maxdepth 1 -name 'YappYapp-*.dmg' | head -n 1)"
  [[ -n "$versioned" ]] || fail "no versioned YappYapp-<version>.dmg in $dir"
  local name version
  name="$(basename "$versioned")"
  version="${name#YappYapp-}"
  version="${version%.dmg}"
  [[ -s "$dir/YappYapp.dmg" ]] || fail "evergreen YappYapp.dmg missing in $dir"
  [[ -s "$dir/checksums.txt" ]] || fail "checksums.txt missing in $dir"

  (cd "$dir" && shasum -a 256 -c checksums.txt >/dev/null) \
    || fail "checksums.txt does not match the staged files in $dir"
  grep -Eq "^[0-9a-f]{64}  $name$" "$dir/checksums.txt" || fail "checksums.txt lacks $name"
  grep -Eq "^[0-9a-f]{64}  YappYapp\.dmg$" "$dir/checksums.txt" || fail "checksums.txt lacks YappYapp.dmg"

  local versioned_sha evergreen_sha
  versioned_sha="$(sha256_of "$versioned")"
  evergreen_sha="$(sha256_of "$dir/YappYapp.dmg")"
  [[ "$versioned_sha" == "$evergreen_sha" ]] \
    || fail "$name ($versioned_sha) and YappYapp.dmg ($evergreen_sha) differ; restage from one DMG"

  if [[ -f "$dir/checksum-line.md" ]]; then
    grep -q "$versioned_sha" "$dir/checksum-line.md" || fail "checksum-line.md does not carry $versioned_sha"
  fi
  if [[ -f "$dir/yappyapp.rb" ]]; then
    grep -q "^  version \"$version\"$" "$dir/yappyapp.rb" || fail "staged cask version is not $version"
    grep -q "^  sha256 \"$versioned_sha\"$" "$dir/yappyapp.rb" || fail "staged cask sha256 is not $versioned_sha"
  fi
  echo "OK   staged release $version: both DMGs identical, sha256 $versioned_sha"
}

if [[ "${1:-}" == "--check" ]]; then
  check_staging "${2:?usage: stage_release_assets.sh --check <dir>}"
  exit 0
fi

VERSION="${YAPPYAPP_RELEASE_VERSION:-$(plutil -extract app.short_version raw -o - "$PROVENANCE")}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail "unexpected version: $VERSION"
SOURCE_DMG="$DIST_DIR/YappYapp.dmg"
[[ -s "$SOURCE_DMG" ]] || fail "missing $SOURCE_DMG; run scripts/package_app.sh and scripts/create_dmg.sh"

STAGE_DIR="$DIST_DIR/release-$VERSION"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -p "$SOURCE_DMG" "$STAGE_DIR/YappYapp-$VERSION.dmg"
cp -p "$SOURCE_DMG" "$STAGE_DIR/YappYapp.dmg"

(
  cd "$STAGE_DIR"
  shasum -a 256 "YappYapp-$VERSION.dmg" "YappYapp.dmg"
) > "$STAGE_DIR/checksums.txt"

SHA="$(sha256_of "$STAGE_DIR/YappYapp-$VERSION.dmg")"
printf "SHA-256 (YappYapp-%s.dmg and YappYapp.dmg): %s\n" "$VERSION" "$SHA" > "$STAGE_DIR/checksum-line.md"
render_cask "$VERSION" "$SHA" "$STAGE_DIR/yappyapp.rb"

check_staging "$STAGE_DIR"
echo "Staged $STAGE_DIR"

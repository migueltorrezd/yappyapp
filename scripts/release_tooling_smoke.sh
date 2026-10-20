#!/usr/bin/env bash
set -euo pipefail

# Offline checks for the publish tooling (YA-07, YA-08, YA-09, YA-43, YA-45,
# YA-76). Uses fake DMGs in a temp folder; never touches the network, the
# keychain or a real release.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/yappyapp-release-tooling.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
CASK="$ROOT_DIR/packaging/homebrew/yappyapp.rb"
VERSION="$(plutil -extract app.short_version raw -o - "$ROOT_DIR/docs/RELEASE_PROVENANCE.json")"
BUILD="$(plutil -extract app.bundle_version raw -o - "$ROOT_DIR/docs/RELEASE_PROVENANCE.json")"

fail() {
  echo "FAIL $*" >&2
  exit 1
}

ok() {
  echo "OK   $*"
}

# YA-07: nothing that ships points at the old matd97 owner. The only allowed
# mentions are the "untap" migration hint, the matd97-bridge/ folder name
# and the bridge tooling itself.
offenders="$(
  cd "$ROOT_DIR"
  grep -rnE "matd97([^-]|$)" Sources scripts packaging .github YappYapp.entitlements 2>/dev/null \
    | grep -v "untap" \
    | grep -v "^scripts/sync_matd97_bridge.sh:" \
    | grep -v "^scripts/publish_release.sh:" \
    | grep -v "^scripts/release_tooling_smoke.sh:" || true
)"
[[ -z "$offenders" ]] || fail "matd97 still referenced:"$'\n'"$offenders"
grep -q "<string>https://raw.githubusercontent.com/migueltorrezd/yappyapp-releases/main/appcast.xml</string>" \
  "$ROOT_DIR/scripts/package_app.sh" || fail "package_app.sh SUFeedURL is not the migueltorrezd feed"
ok "shipped URLs use migueltorrezd"

# YA-08: one version everywhere it is defined.
grep -q "^  version \"$VERSION\"$" "$CASK" || fail "cask version is not $VERSION"
[[ "$BUILD" =~ ^[0-9]+$ ]] || fail "bundle_version is not an integer: $BUILD"
YAPPYAPP_PUBLISHED_TAG="v$VERSION" YAPPYAPP_PUBLISHED_BUILD="$BUILD" \
  "$ROOT_DIR/scripts/check_version_bump.sh" >/dev/null 2>&1 \
  && fail "check_version_bump.sh accepted a version equal to the published tag"
ok "version $VERSION (build $BUILD) is consistent and a reused tag fails"

# YA-43, YA-45: cask requirements.
ruby -c "$CASK" >/dev/null || fail "cask does not parse"
grep -q "depends_on arch: :arm64" "$CASK" || fail "cask lacks depends_on arch: :arm64"
{ grep -qE "^  zap (script|trash):" "$CASK" && grep -qE "^ +trash: +\[" "$CASK"; } || fail "cask lacks a zap stanza that trashes app data"
grep -q "tccutil" "$CASK" || fail "cask zap does not reset privacy grants"
grep -q "xattr" "$CASK" && fail "cask still tells users to strip quarantine"
ok "cask requires arm64, zaps app data and privacy grants"

# YA-76: per-item appcast URLs.
cat > "$TMP_DIR/appcast.xml" <<'EOF'
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <item><enclosure url="https://github.com/migueltorrezd/yappyapp-releases/releases/download/v9.9.9/YappYapp-0.3.1.dmg" length="1"/></item>
        <item><enclosure url="https://example.com/YappYapp-9.9.9.dmg" length="1"/></item>
    </channel>
</rss>
EOF
"$ROOT_DIR/scripts/generate_appcast.sh" --fix-urls "$TMP_DIR/appcast.xml"
grep -q 'releases/download/v0.3.1/YappYapp-0.3.1.dmg"' "$TMP_DIR/appcast.xml" || fail "0.3.1 enclosure not moved to its own tag"
grep -q 'releases/download/v9.9.9/YappYapp-9.9.9.dmg"' "$TMP_DIR/appcast.xml" || fail "9.9.9 enclosure not rewritten"
sed -i '' 's#YappYapp-9.9.9.dmg#YappYapp.dmg#' "$TMP_DIR/appcast.xml"
if "$ROOT_DIR/scripts/generate_appcast.sh" --fix-urls "$TMP_DIR/appcast.xml" 2>/dev/null; then
  fail "an unversioned enclosure was accepted"
fi
ok "appcast enclosures point at their own release tag"

# YA-09, YA-76: staged assets share one checksum, and drift is caught.
mkdir -p "$TMP_DIR/dist"
head -c 65536 /dev/urandom > "$TMP_DIR/dist/YappYapp.dmg"
YAPPYAPP_DIST_DIR="$TMP_DIR/dist" "$ROOT_DIR/scripts/stage_release_assets.sh" >/dev/null
STAGE="$TMP_DIR/dist/release-$VERSION"
sha="$(shasum -a 256 "$TMP_DIR/dist/YappYapp.dmg" | awk '{print $1}')"
grep -q "^  sha256 \"$sha\"$" "$STAGE/yappyapp.rb" || fail "staged cask sha256 is not the DMG checksum"
grep -q "$sha" "$STAGE/checksum-line.md" || fail "checksum line is not the DMG checksum"
printf "x" >> "$STAGE/YappYapp.dmg"
if "$ROOT_DIR/scripts/stage_release_assets.sh" --check "$STAGE" 2>/dev/null; then
  fail "a changed evergreen DMG passed the staging check"
fi
ok "release staging writes one checksum and catches drift"

YAPPYAPP_DIST_DIR="$TMP_DIR/dist" "$ROOT_DIR/scripts/write_checksums.sh" >/dev/null
(cd "$TMP_DIR/dist" && shasum -a 256 -c checksums.txt >/dev/null) || fail "write_checksums.sh output does not verify"
ok "dist checksums describe the files on disk"

# YA-07: bridge sync.
mkdir -p "$TMP_DIR/bridge"
YAPPYAPP_BRIDGE_DIR="$TMP_DIR/bridge" "$ROOT_DIR/scripts/sync_matd97_bridge.sh" "$TMP_DIR/appcast.xml" "$STAGE/yappyapp.rb" >/dev/null
YAPPYAPP_BRIDGE_DIR="$TMP_DIR/bridge" "$ROOT_DIR/scripts/sync_matd97_bridge.sh" --check "$TMP_DIR/appcast.xml" "$STAGE/yappyapp.rb" >/dev/null
printf "\n" >> "$TMP_DIR/bridge/appcast.xml"
if YAPPYAPP_BRIDGE_DIR="$TMP_DIR/bridge" "$ROOT_DIR/scripts/sync_matd97_bridge.sh" --check "$TMP_DIR/appcast.xml" 2>/dev/null; then
  fail "a drifted bridge appcast passed the check"
fi
ok "matd97 bridge sync and drift check work"

# YA-09: publish step 3 extracts the notes template by its heading.
[[ "$(grep -c '^## YappYapp <version>$' "$ROOT_DIR/docs/RELEASE_CHECKLIST.md")" == "1" ]] \
  || fail "docs/RELEASE_CHECKLIST.md needs exactly one '## YappYapp <version>' template heading"

# YA-09: the publish script prints a plan and runs nothing by default.
plan="$("$ROOT_DIR/scripts/publish_release.sh" </dev/null)"
grep -q "Nothing runs without --execute" <<<"$plan" || fail "publish_release.sh did not print a dry plan"
grep -q "gh release create 'v$VERSION'" <<<"$plan" || fail "publish plan lacks the release upload"
grep -q "Confirm the key backups" <<<"$plan" || fail "publish plan lacks the key backup step"
ok "publish_release.sh prints the plan without --execute"

echo "Release tooling smoke passed."

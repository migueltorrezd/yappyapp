#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
SUPPORT_BASE="$TMP_DIR/Application Support"
APP_SUPPORT="$SUPPORT_BASE/YappYapp"
EXPORT_PATH="$TMP_DIR/yappyapp-settings.zip"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "FAIL $*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "missing file: $1"
}

assert_not_exists() {
  [[ ! -e "$1" ]] || fail "expected path to be absent: $1"
}

assert_plutil_raw() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(plutil -extract "$key" raw "$APP_SUPPORT/config.json")"
  [[ "$actual" == "$expected" ]] || fail "expected $key '$expected', got '$actual'"
}

cd "$ROOT_DIR"

mkdir -p "$SUPPORT_BASE"

echo "== Prepare isolated settings =="
YAPPYAPP_APP_SUPPORT_BASE="$SUPPORT_BASE" swift run YappYapp --prepare-support >/dev/null
assert_file "$APP_SUPPORT/config.json"
assert_file "$APP_SUPPORT/glossary.json"

plutil -replace language -string fr "$APP_SUPPORT/config.json"
cat > "$APP_SUPPORT/stats.json" <<'EOF'
{
  "totalDictations": 7
}
EOF

echo "== Export settings =="
YAPPYAPP_APP_SUPPORT_BASE="$SUPPORT_BASE" ./scripts/export_settings.sh "$EXPORT_PATH"
assert_file "$EXPORT_PATH"

LISTING="$(mktemp)"
unzip -Z1 "$EXPORT_PATH" > "$LISTING"
grep -q "^YappYapp-settings/config.json$" "$LISTING" || fail "config.json missing from export"
grep -q "^YappYapp-settings/glossary.json$" "$LISTING" || fail "glossary.json missing from export"
grep -q "^YappYapp-settings/stats.json$" "$LISTING" || fail "stats.json missing from export"
grep -q "^YappYapp-settings/MANIFEST.txt$" "$LISTING" || fail "manifest missing from export"
if grep -Eq "models/|server\\.log|\\.wav|transcript" "$LISTING"; then
  fail "export included files outside the settings allowlist"
fi
rm -f "$LISTING"

echo "== Dry-run import =="
plutil -replace language -string en "$APP_SUPPORT/config.json"
YAPPYAPP_APP_SUPPORT_BASE="$SUPPORT_BASE" ./scripts/import_settings.sh "$EXPORT_PATH" | grep -q "Dry run only" \
  || fail "import did not dry-run by default"
assert_plutil_raw language en

echo "== Apply import =="
YAPPYAPP_APP_SUPPORT_BASE="$SUPPORT_BASE" ./scripts/import_settings.sh --apply "$EXPORT_PATH"
assert_plutil_raw language fr

backup_count="$(find "$APP_SUPPORT/settings-backups" -type f -name "yappyapp-settings-before-import-*.zip" | wc -l | tr -d " ")"
[[ "$backup_count" == "1" ]] || fail "expected one pre-import backup, got $backup_count"
assert_not_exists "$APP_SUPPORT/models/ggml-from-backup.bin"

echo "Settings backup smoke passed."

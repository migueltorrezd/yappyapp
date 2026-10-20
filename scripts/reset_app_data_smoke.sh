#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
SUPPORT_BASE="$TMP_DIR/Application Support"
APP_SUPPORT="$SUPPORT_BASE/YappYapp"
BACKUP_PATH="$TMP_DIR/reset-backup.zip"

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

assert_dir() {
  [[ -d "$1" ]] || fail "missing directory: $1"
}

assert_not_exists() {
  [[ ! -e "$1" ]] || fail "expected path to be absent: $1"
}

cd "$ROOT_DIR"

mkdir -p "$APP_SUPPORT/models" "$APP_SUPPORT/settings-backups"
cat > "$APP_SUPPORT/config.json" <<'EOF'
{
  "whisperBinaryPath": "/opt/homebrew/bin/whisper-cli",
  "modelPath": "~/Library/Application Support/YappYapp/models/ggml-large-v3-turbo.bin",
  "language": "auto",
  "additionalPrompt": "",
  "maxRecordingSeconds": 300,
  "restoreClipboardAfterPaste": true,
  "pasteWhenFocusIsUnclear": true
}
EOF
printf "[]\n" > "$APP_SUPPORT/glossary.json"
printf "{\"totalDictations\": 3}\n" > "$APP_SUPPORT/stats.json"
printf "server log\n" > "$APP_SUPPORT/server.log"
printf "ok\n" > "$APP_SUPPORT/launch-smoke-ok"
printf "model placeholder\n" > "$APP_SUPPORT/models/ggml-placeholder.bin"
printf "backup placeholder\n" > "$APP_SUPPORT/settings-backups/old.zip"

echo "== Reset dry run =="
dry_run_output="$(YAPPYAPP_APP_SUPPORT_BASE="$SUPPORT_BASE" ./scripts/reset_app_data.sh)"
printf "%s\n" "$dry_run_output"
printf "%s\n" "$dry_run_output" | grep -q "Dry run only" \
  || fail "reset did not dry-run by default"
assert_file "$APP_SUPPORT/config.json"
assert_file "$APP_SUPPORT/glossary.json"
assert_file "$APP_SUPPORT/stats.json"
assert_file "$APP_SUPPORT/server.log"
assert_file "$APP_SUPPORT/launch-smoke-ok"
assert_file "$APP_SUPPORT/models/ggml-placeholder.bin"
assert_file "$APP_SUPPORT/settings-backups/old.zip"

echo "== Reset default targets with backup =="
YAPPYAPP_APP_SUPPORT_BASE="$SUPPORT_BASE" ./scripts/reset_app_data.sh --apply --backup "$BACKUP_PATH"
assert_file "$BACKUP_PATH"
assert_not_exists "$APP_SUPPORT/config.json"
assert_not_exists "$APP_SUPPORT/glossary.json"
assert_not_exists "$APP_SUPPORT/stats.json"
assert_not_exists "$APP_SUPPORT/server.log"
assert_not_exists "$APP_SUPPORT/launch-smoke-ok"
assert_file "$APP_SUPPORT/models/ggml-placeholder.bin"
assert_file "$APP_SUPPORT/settings-backups/old.zip"

echo "== Reset optional model and backup directories =="
YAPPYAPP_APP_SUPPORT_BASE="$SUPPORT_BASE" ./scripts/reset_app_data.sh --apply --include-models --include-backups
assert_not_exists "$APP_SUPPORT/models"
assert_not_exists "$APP_SUPPORT/settings-backups"

echo "Reset app data smoke passed."

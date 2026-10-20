#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
SUPPORT_BASE="$TMP_DIR/Application Support"
APP_SUPPORT="$SUPPORT_BASE/YappYapp"
LEGACY_SUPPORT="$SUPPORT_BASE/YappYappLegacy"

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

assert_json() {
  plutil -convert json -o /dev/null -- "$1" >/dev/null 2>&1 || fail "invalid JSON: $1"
}

assert_model_path() {
  local expected="$1"
  local actual
  actual="$(plutil -extract modelPath raw "$APP_SUPPORT/config.json")"
  [[ "$actual" == "$expected" ]] || fail "expected modelPath '$expected', got '$actual'"
}

prepare_support() {
  YAPPYAPP_APP_SUPPORT_BASE="$SUPPORT_BASE" \
    "$ROOT_DIR/.build/debug/YappYapp" --prepare-support
}

reset_support_base() {
  rm -rf "$SUPPORT_BASE"
  mkdir -p "$SUPPORT_BASE"
}

write_legacy_config() {
  local model_path="$1"
  cat > "$2" <<EOF
{
  "whisperBinaryPath": "/opt/homebrew/bin/whisper-cli",
  "modelPath": "$model_path",
  "language": "auto",
  "additionalPrompt": "vocab",
  "maxRecordingSeconds": 300,
  "restoreClipboardAfterPaste": true,
  "pasteWhenFocusIsUnclear": true
}
EOF
}

cd "$ROOT_DIR"
# YA-06: pick a macOS SDK whose SwiftUI macros this toolchain can expand.
# shellcheck source=scripts/lib/swift_sdk.sh
source "$ROOT_DIR/scripts/lib/swift_sdk.sh"
yappyapp_use_buildable_sdk || exit 1
swift build >/dev/null

echo "== Clean first launch =="
reset_support_base
prepare_support
assert_dir "$APP_SUPPORT"
assert_dir "$APP_SUPPORT/models"
assert_file "$APP_SUPPORT/config.json"
assert_file "$APP_SUPPORT/glossary.json"
assert_json "$APP_SUPPORT/config.json"
assert_json "$APP_SUPPORT/glossary.json"
assert_model_path "parakeet://ultra"

echo "== Idempotent first launch =="
prepare_support
assert_file "$APP_SUPPORT/config.json"
assert_file "$APP_SUPPORT/glossary.json"
assert_model_path "parakeet://ultra"

echo "== Legacy folder migration =="
reset_support_base
mkdir -p "$LEGACY_SUPPORT/models"
printf "legacy model\n" > "$LEGACY_SUPPORT/models/ggml-tiny.en.bin"
write_legacy_config "$LEGACY_SUPPORT/models/ggml-tiny.en.bin" "$LEGACY_SUPPORT/config.json"
printf "[]\n" > "$LEGACY_SUPPORT/glossary.json"
prepare_support
assert_dir "$APP_SUPPORT"
assert_not_exists "$LEGACY_SUPPORT"
assert_file "$APP_SUPPORT/models/ggml-tiny.en.bin"
assert_model_path "$APP_SUPPORT/models/ggml-tiny.en.bin"

echo "== Mixed folder merge =="
reset_support_base
mkdir -p "$APP_SUPPORT" "$LEGACY_SUPPORT/models"
printf "legacy model\n" > "$LEGACY_SUPPORT/models/ggml-small.bin"
write_legacy_config "$LEGACY_SUPPORT/models/ggml-small.bin" "$APP_SUPPORT/config.json"
printf "[]\n" > "$LEGACY_SUPPORT/glossary.json"
prepare_support
assert_dir "$APP_SUPPORT/models"
assert_file "$APP_SUPPORT/models/ggml-small.bin"
assert_file "$APP_SUPPORT/glossary.json"
assert_model_path "$APP_SUPPORT/models/ggml-small.bin"

echo "Clean install smoke passed."

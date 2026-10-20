#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
SUPPORT_BASE="$TMP_DIR/Application Support"
APP_SUPPORT="$SUPPORT_BASE/YappYapp"
CONFIG="$APP_SUPPORT/config.json"

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

assert_json() {
  plutil -convert json -o /dev/null -- "$1" >/dev/null 2>&1 || fail "invalid JSON: $1"
}

assert_plutil_raw() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(plutil -extract "$key" raw "$CONFIG")"
  [[ "$actual" == "$expected" ]] || fail "expected $key '$expected', got '$actual'"
}

cd "$ROOT_DIR"

mkdir -p "$SUPPORT_BASE"

echo "== Source install smoke =="
setup_output="$(YAPPYAPP_APP_SUPPORT_BASE="$SUPPORT_BASE" ./scripts/setup_source_install.sh --runtime none 2>&1)"
printf "%s\n" "$setup_output"

assert_dir "$APP_SUPPORT"
assert_dir "$APP_SUPPORT/models"
assert_file "$CONFIG"
assert_file "$APP_SUPPORT/glossary.json"
assert_json "$CONFIG"
assert_json "$APP_SUPPORT/glossary.json"
assert_plutil_raw modelPath "parakeet://ultra"
assert_plutil_raw allowModelDownloads true

if find "$APP_SUPPORT/models" -type f -name "ggml-*.bin" | grep -q .; then
  fail "source setup downloaded model weights without --model or --all-models"
fi
if printf "%s\n" "$setup_output" | grep -Eq "Downloading|== Install Whisper model ==|== Install all Whisper models =="; then
  fail "source setup attempted a model download without --model or --all-models"
fi

printf "%s\n" "$setup_output" | grep -q "Source setup complete." \
  || fail "setup script did not complete"
printf "%s\n" "$setup_output" | grep -Eq "Run from source with: (SDKROOT=.* )?swift run YappYapp" \
  || fail "setup script did not print source run command"

echo "== Idempotent source setup =="
YAPPYAPP_APP_SUPPORT_BASE="$SUPPORT_BASE" ./scripts/setup_source_install.sh --runtime none --skip-doctor >/dev/null
assert_file "$CONFIG"
assert_plutil_raw modelPath "parakeet://ultra"

echo "== Model installer validation =="
install_error="$TMP_DIR/install-model-error.log"
if YAPPYAPP_APP_SUPPORT="$APP_SUPPORT" ./scripts/install_model.sh not-a-real-model >"$TMP_DIR/install-model-output.log" 2>"$install_error"; then
  fail "install_model.sh accepted an unsupported model name"
fi
grep -q "unsupported Whisper model 'not-a-real-model'" "$install_error" \
  || fail "install_model.sh did not explain unsupported model names"
grep -q "large-v3-turbo" "$install_error" \
  || fail "install_model.sh did not list supported models"
if find "$APP_SUPPORT/models" -type f -name "ggml-not-a-real-model.bin*" | grep -q .; then
  fail "install_model.sh created files for an unsupported model"
fi

echo "Source install smoke passed."

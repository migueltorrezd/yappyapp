#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
SUPPORT_BASE="$TMP_DIR/Application Support"
APP_SUPPORT="$SUPPORT_BASE/YappYapp"
MODEL_PATH="$APP_SUPPORT/models/ggml-managed-local.bin"

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

assert_json() {
  plutil -convert json -o /dev/null -- "$1" >/dev/null 2>&1 || fail "invalid JSON: $1"
}

assert_plutil_raw() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(plutil -extract "$key" raw "$APP_SUPPORT/config.json")"
  [[ "$actual" == "$expected" ]] || fail "expected $key '$expected', got '$actual'"
}

prepare_support() {
  YAPPYAPP_APP_SUPPORT_BASE="$SUPPORT_BASE" \
    "$ROOT_DIR/.build/debug/YappYapp" --prepare-support >/dev/null
}

cd "$ROOT_DIR"
# YA-06: pick a macOS SDK whose SwiftUI macros this toolchain can expand.
# shellcheck source=scripts/lib/swift_sdk.sh
source "$ROOT_DIR/scripts/lib/swift_sdk.sh"
yappyapp_use_buildable_sdk || exit 1
swift build >/dev/null

mkdir -p "$SUPPORT_BASE"

echo "== Offline managed config =="
prepare_support
assert_file "$APP_SUPPORT/config.json"
assert_json "$APP_SUPPORT/config.json"

mkdir -p "$(dirname "$MODEL_PATH")"
printf "managed model placeholder\n" > "$MODEL_PATH"
plutil -replace allowModelDownloads -bool NO "$APP_SUPPORT/config.json"
plutil -replace modelPath -string "$MODEL_PATH" "$APP_SUPPORT/config.json"

assert_plutil_raw allowModelDownloads false
assert_plutil_raw modelPath "$MODEL_PATH"

echo "== Offline config survives support preparation =="
prepare_support
assert_file "$MODEL_PATH"
assert_plutil_raw allowModelDownloads false
assert_plutil_raw modelPath "$MODEL_PATH"

echo "== Offline doctor view =="
doctor_output="$(YAPPYAPP_APP_SUPPORT_BASE="$SUPPORT_BASE" ./scripts/doctor.sh)"
printf "%s\n" "$doctor_output"
printf "%s\n" "$doctor_output" | grep -q "model downloads are disabled in config.json" \
  || fail "doctor did not report disabled model downloads"
printf "%s\n" "$doctor_output" | grep -q "Whisper models installed in $APP_SUPPORT/models" \
  || fail "doctor did not find the managed local model"
printf "%s\n" "$doctor_output" | grep -q "configured Whisper model exists: $MODEL_PATH" \
  || fail "doctor did not validate the configured managed model path"
printf "%s\n" "$doctor_output" | grep -q "configured Whisper model has no registered checksum" \
  || fail "doctor did not flag the custom managed model checksum posture"

echo "== Offline doctor rejects corrupt registered model =="
REGISTERED_MODEL="$APP_SUPPORT/models/ggml-tiny.en.bin"
printf "not the real tiny model\n" > "$REGISTERED_MODEL"
plutil -replace modelPath -string "$REGISTERED_MODEL" "$APP_SUPPORT/config.json"
if corrupt_output="$(YAPPYAPP_APP_SUPPORT_BASE="$SUPPORT_BASE" ./scripts/doctor.sh 2>&1)"; then
  printf "%s\n" "$corrupt_output"
  fail "doctor accepted a corrupt registered Whisper model"
fi
printf "%s\n" "$corrupt_output" | grep -q "configured Whisper model checksum mismatch for ggml-tiny.en.bin" \
  || fail "doctor did not report the corrupt registered model checksum"

echo "== Offline doctor rejects missing Parakeet cache =="
plutil -replace modelPath -string "parakeet://v3" "$APP_SUPPORT/config.json"
plutil -replace whisperBinaryPath -string "$TMP_DIR/missing-whisper-cli" "$APP_SUPPORT/config.json"
if missing_parakeet_output="$(
  YAPPYAPP_APP_SUPPORT_BASE="$SUPPORT_BASE" \
    YAPPYAPP_DIAGNOSTIC_EXEC="$ROOT_DIR/.build/debug/YappYapp" \
    YAPPYAPP_PARAKEET_CACHE_STATUS_OVERRIDE=missing \
    ./scripts/doctor.sh 2>&1
)"; then
  printf "%s\n" "$missing_parakeet_output"
  fail "doctor accepted a missing offline Parakeet cache"
fi
printf "%s\n" "$missing_parakeet_output" | grep -q "selected model uses Parakeet: parakeet://v3" \
  || fail "doctor did not report the selected Parakeet model"
printf "%s\n" "$missing_parakeet_output" | grep -q "selected Parakeet model cache is missing while downloads are disabled" \
  || fail "doctor did not reject the missing offline Parakeet cache"

echo "== Offline doctor accepts installed Parakeet cache =="
installed_parakeet_output="$(
  YAPPYAPP_APP_SUPPORT_BASE="$SUPPORT_BASE" \
    YAPPYAPP_DIAGNOSTIC_EXEC="$ROOT_DIR/.build/debug/YappYapp" \
    YAPPYAPP_PARAKEET_CACHE_STATUS_OVERRIDE=installed \
    ./scripts/doctor.sh
)"
printf "%s\n" "$installed_parakeet_output"
printf "%s\n" "$installed_parakeet_output" | grep -q "selected Parakeet model cache is installed" \
  || fail "doctor did not accept the installed offline Parakeet cache"
printf "%s\n" "$installed_parakeet_output" | grep -q "configured whisper-cli is not required for the selected Parakeet model" \
  || fail "doctor still required whisper-cli for the selected Parakeet model"

echo "Offline managed config smoke passed."

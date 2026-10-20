#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/YappYapp.app"
APP_EXEC="$APP_DIR/Contents/MacOS/YappYapp"
TMP_DIR="$(mktemp -d)"
SUPPORT_BASE="$TMP_DIR/Application Support"
APP_SUPPORT="$SUPPORT_BASE/YappYapp"

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

cd "$ROOT_DIR"

if [[ ! -x "$APP_EXEC" ]]; then
  echo "Packaged app missing; building dist/YappYapp.app first."
  # FIX signing-identity: do not force ad-hoc ("-"). Let package_app.sh discover
  # the stable identity; forcing "-" here would silently re-sign an existing
  # dist bundle ad-hoc and break its TCC Accessibility grant.
  ./scripts/package_app.sh
fi

echo "== Packaged app launch smoke =="
mkdir -p "$SUPPORT_BASE"
LOG="$TMP_DIR/launch.log"

YAPPYAPP_APP_SUPPORT_BASE="$SUPPORT_BASE" "$APP_EXEC" --launch-smoke >"$LOG" 2>&1 &
pid=$!

for _ in {1..80}; do
  if ! kill -0 "$pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

if kill -0 "$pid" 2>/dev/null; then
  kill "$pid" 2>/dev/null || true
  sleep 0.5
  kill -9 "$pid" 2>/dev/null || true
  cat "$LOG" >&2
  fail "packaged app did not exit from --launch-smoke"
fi

# FIX wait-diagnostics: capture the exit status without letting `set -e` abort
# on a non-zero app exit, so the log dump and failure message below still run.
wait "$pid" && status=0 || status=$?
cat "$LOG"
[[ "$status" -eq 0 ]] || fail "packaged app exited with $status"
grep -q "launchSmoke=ok" "$LOG" || fail "launch smoke completion marker missing"

assert_dir "$APP_SUPPORT"
assert_dir "$APP_SUPPORT/models"
assert_file "$APP_SUPPORT/config.json"
assert_file "$APP_SUPPORT/glossary.json"
assert_file "$APP_SUPPORT/launch-smoke-ok"
assert_json "$APP_SUPPORT/config.json"
assert_json "$APP_SUPPORT/glossary.json"

expected_cli="$APP_DIR/Contents/Resources/bin/whisper-cli"
actual_cli="$(plutil -extract whisperBinaryPath raw "$APP_SUPPORT/config.json")"
[[ "$actual_cli" == "$expected_cli" ]] || fail "expected bundled whisperBinaryPath '$expected_cli', got '$actual_cli'"

model_path="$(plutil -extract modelPath raw "$APP_SUPPORT/config.json")"
[[ "$model_path" == "parakeet://ultra" ]] || fail "unexpected modelPath '$model_path'"

echo "Packaged app launch smoke passed."

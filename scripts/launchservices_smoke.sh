#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/YappYapp.app"
APP_EXEC="$APP_DIR/Contents/MacOS/YappYapp"
TMP_DIR="$(mktemp -d)"
SUPPORT_BASE="$TMP_DIR/Application Support"
APP_SUPPORT="$SUPPORT_BASE/YappYapp"
ENV_KEY="YAPPYAPP_APP_SUPPORT_BASE"
HAD_PREVIOUS_ENV=0
PREVIOUS_ENV=""
PROCESS_PATTERN="[Y]appYapp.*--launch-smoke"

cleanup() {
  if [[ "$HAD_PREVIOUS_ENV" -eq 1 ]]; then
    launchctl setenv "$ENV_KEY" "$PREVIOUS_ENV" >/dev/null 2>&1 || true
  else
    launchctl unsetenv "$ENV_KEY" >/dev/null 2>&1 || true
  fi

  if pgrep -fl "$PROCESS_PATTERN" >/dev/null 2>&1; then
    pkill -f "$PROCESS_PATTERN" >/dev/null 2>&1 || true
  fi

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

is_temporary_support_base() {
  local value="$1"
  case "$value" in
    /var/folders/*/T/tmp.*/Application\ Support|/tmp/tmp.*/Application\ Support)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

cd "$ROOT_DIR"

if [[ ! -x "$APP_EXEC" ]]; then
  echo "Packaged app missing; building dist/YappYapp.app first."
  # SIGN-IDENTITY-PASSTHROUGH: do not force ad-hoc ("-") signing here. Forcing a
  # default identity defeats package_app.sh's Developer ID auto-discovery and
  # destabilizes TCC grants (re-signing changes the code identity). Pass
  # SIGN_IDENTITY through only when the caller set it explicitly.
  if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$SIGN_IDENTITY" ./scripts/package_app.sh
  else
    ./scripts/package_app.sh
  fi
fi

echo "== LaunchServices smoke =="
mkdir -p "$SUPPORT_BASE"

if previous="$(launchctl getenv "$ENV_KEY" 2>/dev/null)"; then
  if [[ -n "$previous" ]]; then
    if is_temporary_support_base "$previous"; then
      echo "Ignoring temporary $ENV_KEY from a previous smoke run: $previous"
    else
      HAD_PREVIOUS_ENV=1
      PREVIOUS_ENV="$previous"
    fi
  fi
fi

launchctl setenv "$ENV_KEY" "$SUPPORT_BASE"
# Recent macOS no longer hands launchctl's user environment to apps started by
# `open`, so pass the isolated support base explicitly as well.
open -n --env "$ENV_KEY=$SUPPORT_BASE" "$APP_DIR" --args --launch-smoke

for _ in {1..120}; do
  if [[ -f "$APP_SUPPORT/launch-smoke-ok" ]]; then
    break
  fi
  sleep 0.1
done

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

for _ in {1..30}; do
  if ! pgrep -fl "$PROCESS_PATTERN" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

if pgrep -fl "$PROCESS_PATTERN" >/dev/null 2>&1; then
  fail "LaunchServices smoke process did not exit"
fi

echo "LaunchServices smoke passed."

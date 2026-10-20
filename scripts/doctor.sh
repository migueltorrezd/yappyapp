#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/YappYapp.app"
APP_EXEC="$APP_DIR/Contents/MacOS/YappYapp"
DIAGNOSTIC_EXEC="${YAPPYAPP_DIAGNOSTIC_EXEC:-$APP_EXEC}"
APP_SUPPORT_BASE="${YAPPYAPP_APP_SUPPORT_BASE:-$HOME/Library/Application Support}"
APP_SUPPORT="$APP_SUPPORT_BASE/YappYapp"
LEGACY_APP_SUPPORT="$APP_SUPPORT_BASE/YappYappLegacy"

ACTIVE_APP_SUPPORT="$APP_SUPPORT"
if [[ ! -d "$APP_SUPPORT" && -d "$LEGACY_APP_SUPPORT" ]]; then
  ACTIVE_APP_SUPPORT="$LEGACY_APP_SUPPORT"
fi
MODEL_DIR="$ACTIVE_APP_SUPPORT/models"
# shellcheck source=scripts/lib/swift_sdk.sh
source "$ROOT_DIR/scripts/lib/swift_sdk.sh"

failures=0
warnings=0

ok() {
  printf "OK   %s\n" "$1"
}

warn() {
  warnings=$((warnings + 1))
  printf "WARN %s\n" "$1"
}

info() {
  printf "INFO %s\n" "$1"
}

fail() {
  failures=$((failures + 1))
  printf "FAIL %s\n" "$1"
}

has_command() {
  command -v "$1" >/dev/null 2>&1
}

expand_path() {
  local path="$1"
  # The ~/ branch matches a literal config token, not shell expansion.
  # shellcheck disable=SC2088
  case "$path" in
    "~") printf "%s\n" "$HOME" ;;
    "~/"*) printf "%s/%s\n" "$HOME" "${path#"~/"}" ;;
    *) printf "%s\n" "$path" ;;
  esac
}

config_raw_value() {
  local key="$1"
  plutil -extract "$key" raw "$ACTIVE_APP_SUPPORT/config.json" 2>/dev/null || true
}

permission_raw_value() {
  local key="$1"
  local output="$2"
  awk -F= -v key="$key" '$1 == key { print $2; exit }' <<<"$output"
}

app_diagnostic_output() {
  local output_file
  local pid
  local diagnostic_status=0

  output_file="$(mktemp)"
  "$DIAGNOSTIC_EXEC" "$@" >"$output_file" 2>/dev/null &
  pid=$!

  for _ in {1..50}; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" || diagnostic_status=$?
      cat "$output_file"
      rm -f "$output_file"
      return "$diagnostic_status"
    fi
    sleep 0.1
  done

  kill "$pid" 2>/dev/null || true
  sleep 0.2
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$output_file"
  return 124
}

expected_model_sha1() {
  case "$(basename "$1")" in
    ggml-large-v3-turbo.bin) echo "4af2b29d7ec73d781377bfd1758ca957a807e941" ;;
    ggml-large-v3.bin) echo "ad82bf6a9043ceed055076d0fd39f5f186ff8062" ;;
    ggml-medium.bin) echo "fd9727b6e1217c2f614f9b698455c4ffd82463b4" ;;
    ggml-small.bin) echo "55356645c2b361a969dfd0ef2c5a50d530afd8d5" ;;
    ggml-base.bin) echo "465707469ff3a37a2b9b8d8f89f2f99de7299dac" ;;
    ggml-tiny.bin) echo "bd577a113a864445d4c299885e0cb97d4ba92b5f" ;;
    ggml-medium.en.bin) echo "8c30f0e44ce9560643ebd10bbe50cd20eafd3723" ;;
    ggml-small.en.bin) echo "db8a495a91d927739e50b3fc1cc4c6b8f6c2d022" ;;
    ggml-base.en.bin) echo "137c40403d78fd54d454da0f9bd998f78703390c" ;;
    ggml-tiny.en.bin) echo "c78c86eb1a8faa21b369bcd33207cc90d64ae9df" ;;
    *) echo "" ;;
  esac
}

verify_configured_model_checksum() {
  local model_path="$1"
  local expected
  local actual

  expected="$(expected_model_sha1 "$model_path")"
  if [[ -z "$expected" ]]; then
    warn "configured Whisper model has no registered checksum; verify manually: $model_path"
    return
  fi

  actual="$(shasum -a 1 "$model_path" 2>/dev/null | awk '{print $1}')"
  if [[ "$actual" == "$expected" ]]; then
    ok "configured Whisper model checksum verifies: $(basename "$model_path")"
  else
    fail "configured Whisper model checksum mismatch for $(basename "$model_path"): expected $expected, got ${actual:-unreadable}"
  fi
}

printf "YappYapp doctor\n"
printf "Root: %s\n\n" "$ROOT_DIR"
if [[ -n "${YAPPYAPP_APP_SUPPORT_BASE:-}" ]]; then
  ok "using support base override: $APP_SUPPORT_BASE"
fi
if [[ -n "${YAPPYAPP_DIAGNOSTIC_EXEC:-}" ]]; then
  ok "using diagnostic executable override: $DIAGNOSTIC_EXEC"
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
  macos_version="$(sw_vers -productVersion 2>/dev/null || printf "unknown")"
  macos_major="${macos_version%%.*}"
  if [[ "$macos_major" =~ ^[0-9]+$ ]] && (( macos_major >= 14 )); then
    ok "macOS $macos_version meets the 14+ requirement"
  else
    fail "macOS $macos_version is below the 14+ requirement"
  fi
else
  fail "YappYapp is a macOS app; this host is $(uname -s)"
fi

arch="$(uname -m)"
if [[ "$arch" == "arm64" ]]; then
  ok "Apple Silicon architecture detected"
else
  fail "Architecture is $arch; YappYapp requires Apple Silicon (arm64)"
fi

if xcrun --find swift >/dev/null 2>&1; then
  ok "Swift toolchain found: $(xcrun --find swift)"
else
  fail "Swift toolchain not found; install Xcode Command Line Tools"
fi

# YA-06: with Command Line Tools only, the newest SDK may declare SwiftUI
# macros whose plugin ships with Xcode alone. Say so before a build fails.
if [[ -n "${SDKROOT:-}" ]]; then
  if [[ -d "$SDKROOT" ]]; then
    ok "SDKROOT is set: $SDKROOT"
  else
    fail "SDKROOT points to a missing SDK: $SDKROOT"
  fi
elif buildable_sdk="$(yappyapp_find_buildable_sdk)"; then
  if [[ "$buildable_sdk" == "$(yappyapp_sdk_default)" ]]; then
    ok "default macOS SDK builds YappYapp: $buildable_sdk"
  else
    ok "build scripts will use $buildable_sdk (the default SDK needs Xcode's SwiftUI macro plugin)"
  fi
else
  fail "no installed macOS SDK can build YappYapp's SwiftUI views; install Xcode, or Command Line Tools with the macOS 26 SDK"
fi

if has_command cmake; then
  ok "cmake found for building bundled whisper.cpp"
else
  warn "cmake not found; Homebrew whisper-cpp can still be used"
fi

if has_command brew; then
  ok "Homebrew found"
else
  warn "Homebrew not found; install whisper.cpp another way or bundle it"
fi

if [[ -x "$APP_DIR/Contents/Resources/bin/whisper-cli" ]]; then
  ok "packaged whisper-cli is bundled"
elif has_command whisper-cli; then
  ok "system whisper-cli found: $(command -v whisper-cli)"
else
  warn "no whisper-cli found; run brew install whisper-cpp or scripts/bootstrap_whisper_cpp.sh"
fi

if [[ -x "$APP_DIR/Contents/Resources/bin/whisper-server" ]]; then
  ok "packaged whisper-server is bundled"
elif has_command whisper-server; then
  ok "system whisper-server found: $(command -v whisper-server)"
else
  warn "no whisper-server found; warm Whisper mode will fall back to whisper-cli"
fi

# LLM-CLEANUP (YA-10): optional cleanup needs the bundled llama.cpp runtime.
if [[ -x "$APP_DIR/Contents/Resources/bin/llama-completion" ]]; then
  ok "packaged llama-completion (LLM cleanup runtime) is bundled"
elif has_command llama-cli; then
  ok "system llama-cli found for LLM cleanup: $(command -v llama-cli)"
else
  warn "no LLM cleanup runtime found; run scripts/bootstrap_llama_cpp.sh before packaging"
fi

if [[ "$ACTIVE_APP_SUPPORT" == "$LEGACY_APP_SUPPORT" ]]; then
  ok "previous support folder found; first YappYapp launch will migrate it"
elif [[ -d "$APP_SUPPORT" ]]; then
  ok "YappYapp support folder exists: $APP_SUPPORT"
else
  warn "support folder has not been created yet: $APP_SUPPORT"
fi
if [[ "$ACTIVE_APP_SUPPORT" != "$LEGACY_APP_SUPPORT" && -d "$LEGACY_APP_SUPPORT" ]]; then
  ok "previous support folder also exists; first YappYapp launch will merge missing files"
fi

if [[ -d "$MODEL_DIR" ]]; then
  shopt -s nullglob
  models=("$MODEL_DIR"/ggml-*.bin)
  shopt -u nullglob
  if (( ${#models[@]} > 0 )); then
    ok "Whisper models installed in $MODEL_DIR (${#models[@]} found)"
  else
    warn "no Whisper models found in $MODEL_DIR"
  fi
else
  warn "model directory has not been created yet: $MODEL_DIR"
fi

if [[ -f "$ACTIVE_APP_SUPPORT/config.json" ]]; then
  if plutil -convert json -o /dev/null -- "$ACTIVE_APP_SUPPORT/config.json" >/dev/null 2>&1; then
    ok "config.json is valid JSON"
    allow_model_downloads="$(config_raw_value allowModelDownloads)"
    configured_whisper_binary="$(config_raw_value whisperBinaryPath)"
    configured_model_path="$(config_raw_value modelPath)"

    if [[ "$allow_model_downloads" == "false" ]]; then
      ok "model downloads are disabled in config.json"
    else
      ok "model downloads are allowed in config.json"
    fi

    if [[ -n "$configured_model_path" ]]; then
      if [[ "$configured_model_path" == parakeet://* ]]; then
        ok "selected model uses Parakeet: $configured_model_path"
        if [[ -x "$DIAGNOSTIC_EXEC" ]]; then
          parakeet_cache_output="$(app_diagnostic_output --parakeet-cache-status "$configured_model_path" || true)"
          parakeet_cache_status="$(permission_raw_value model.cache "$parakeet_cache_output")"
          parakeet_cache_path="$(permission_raw_value model.cache.path "$parakeet_cache_output")"

          case "$parakeet_cache_status" in
            installed)
              ok "selected Parakeet model cache is installed: $parakeet_cache_path"
              ;;
            missing)
              if [[ "$allow_model_downloads" == "false" ]]; then
                fail "selected Parakeet model cache is missing while downloads are disabled: $parakeet_cache_path"
              else
                ok "selected Parakeet model cache is missing; downloads are allowed for first use"
              fi
              ;;
            *)
              warn "could not determine selected Parakeet model cache status"
              ;;
          esac
        elif [[ "$allow_model_downloads" == "false" ]]; then
          warn "app diagnostic executable missing; cannot verify selected Parakeet cache while downloads are disabled"
        fi
      else
        expanded_model_path="$(expand_path "$configured_model_path")"
        if [[ -f "$expanded_model_path" ]]; then
          ok "configured Whisper model exists: $expanded_model_path"
          verify_configured_model_checksum "$expanded_model_path"
        elif [[ "$allow_model_downloads" == "false" ]]; then
          fail "configured Whisper model is missing while downloads are disabled: $expanded_model_path"
        else
          warn "configured Whisper model is missing: $expanded_model_path"
        fi
      fi
    else
      fail "config.json is missing modelPath"
    fi

    if [[ -n "$configured_whisper_binary" ]]; then
      expanded_whisper_binary="$(expand_path "$configured_whisper_binary")"
      if [[ -x "$expanded_whisper_binary" ]]; then
        ok "configured whisper-cli is executable: $expanded_whisper_binary"
      elif [[ "$configured_model_path" == parakeet://* ]]; then
        ok "configured whisper-cli is not required for the selected Parakeet model"
      else
        warn "configured whisper-cli is not executable: $expanded_whisper_binary"
      fi
    else
      fail "config.json is missing whisperBinaryPath"
    fi
  else
    fail "config.json is not valid JSON: $ACTIVE_APP_SUPPORT/config.json"
  fi
else
  warn "config.json does not exist yet; first launch will create it"
fi

if [[ -f "$ACTIVE_APP_SUPPORT/glossary.json" ]]; then
  if plutil -convert json -o /dev/null -- "$ACTIVE_APP_SUPPORT/glossary.json" >/dev/null 2>&1; then
    ok "glossary.json is valid JSON"
  else
    fail "glossary.json is not valid JSON: $ACTIVE_APP_SUPPORT/glossary.json"
  fi
else
  warn "glossary.json does not exist yet; first launch will create it"
fi

if [[ -d "$APP_DIR" ]]; then
  if codesign --verify --deep --strict "$APP_DIR" >/dev/null 2>&1; then
    ok "dist/YappYapp.app code signature verifies"
  else
    fail "dist/YappYapp.app code signature does not verify"
  fi

  if [[ -x "$APP_EXEC" ]]; then
    ok "packaged app executable exists"
  else
    fail "packaged app executable missing: $APP_EXEC"
  fi
else
  warn "dist/YappYapp.app does not exist; run scripts/package_app.sh"
fi

if [[ -x "$APP_EXEC" ]]; then
  permission_output="$("$APP_EXEC" --permissions-status 2>/dev/null || true)"
  microphone_permission="$(permission_raw_value permission.microphone "$permission_output")"
  accessibility_permission="$(permission_raw_value permission.accessibility "$permission_output")"

  case "$microphone_permission" in
    authorized)
      ok "microphone permission is granted"
      ;;
    notDetermined)
      ok "microphone permission has not been requested yet; first recording will prompt"
      ;;
    denied)
      warn "microphone permission is denied; enable it in System Settings -> Privacy & Security -> Microphone"
      ;;
    restricted)
      warn "microphone permission is restricted by macOS or device management"
      ;;
    "")
      warn "could not read microphone permission status from packaged app"
      ;;
    *)
      warn "microphone permission status is unknown: $microphone_permission"
      ;;
  esac

  case "$accessibility_permission" in
    trusted)
      ok "Accessibility permission is granted for auto-paste"
      ;;
    notTrusted)
      ok "Accessibility permission is not granted yet; dictations copy to clipboard until auto-paste is enabled"
      ;;
    "")
      warn "could not read Accessibility permission status from packaged app"
      ;;
    *)
      warn "Accessibility permission status is unknown: $accessibility_permission"
      ;;
  esac
else
  info "permission status check skipped until dist/YappYapp.app exists"
fi

if pgrep -fl "[Y]appYapp.app/Contents/MacOS/YappYapp" >/dev/null 2>&1; then
  ok "YappYapp appears to be running"
else
  warn "YappYapp is not currently running"
fi

printf "\nSummary: %d failure(s), %d warning(s)\n" "$failures" "$warnings"
if (( failures > 0 )); then
  exit 1
fi

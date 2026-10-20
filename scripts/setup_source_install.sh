#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SUPPORT_BASE="${YAPPYAPP_APP_SUPPORT_BASE:-$HOME/Library/Application Support}"
APP_SUPPORT="$APP_SUPPORT_BASE/YappYapp"
CONFIG="$APP_SUPPORT/config.json"
SOURCE_CLI="$ROOT_DIR/vendor/whisper.cpp/build/bin/whisper-cli"
HOMEBREW_CLI="/opt/homebrew/bin/whisper-cli"

RUNTIME_MODE="auto"
MODEL_NAME=""
INSTALL_ALL_MODELS=0
RUN_DOCTOR=1

usage() {
  cat <<EOF
Usage:
  ./scripts/setup_source_install.sh [options]

Prepares a source checkout for local dictation without requiring an API key.
The default mode is conservative: it creates YappYapp support files, detects an
existing whisper-cli runtime, and runs the doctor. It does not download model
weights unless --model or --all-models is provided.

Options:
  --runtime auto       Use an existing runtime when found (default)
  --runtime homebrew   Install/use Homebrew whisper-cpp
  --runtime source     Build vendored whisper.cpp runtime helpers
  --runtime none       Only prepare support files and run diagnostics
  --model MODEL        Download and select one Whisper model, e.g. tiny.en
  --all-models         Download all Whisper models exposed in the picker
  --skip-doctor        Do not run scripts/doctor.sh at the end
  -h, --help           Show this help

Examples:
  ./scripts/setup_source_install.sh --runtime homebrew --model large-v3-turbo
  ./scripts/setup_source_install.sh --runtime source --model tiny.en
  ./scripts/setup_source_install.sh --runtime auto
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime)
      RUNTIME_MODE="${2:-}"
      case "$RUNTIME_MODE" in
        auto|homebrew|source|none) ;;
        *)
          echo "error: --runtime must be auto, homebrew, source, or none" >&2
          exit 2
          ;;
      esac
      shift 2
      ;;
    --model)
      MODEL_NAME="${2:-}"
      if [[ -z "$MODEL_NAME" ]]; then
        echo "error: --model requires a value" >&2
        exit 2
      fi
      shift 2
      ;;
    --all-models)
      INSTALL_ALL_MODELS=1
      shift
      ;;
    --skip-doctor)
      RUN_DOCTOR=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

cd "$ROOT_DIR"
# YA-06: pick a macOS SDK whose SwiftUI macros this toolchain can expand.
# shellcheck source=scripts/lib/swift_sdk.sh
source "$ROOT_DIR/scripts/lib/swift_sdk.sh"
yappyapp_use_buildable_sdk || exit 1

echo "== Prepare support files =="
swift run YappYapp --prepare-support

runtime_cli=""

case "$RUNTIME_MODE" in
  source)
    echo
    echo "== Build vendored whisper.cpp runtime =="
    ./scripts/bootstrap_whisper_cpp.sh --skip-model
    runtime_cli="$SOURCE_CLI"
    ;;
  homebrew)
    echo
    echo "== Install/use Homebrew whisper-cpp runtime =="
    if ! command -v brew >/dev/null 2>&1; then
      echo "error: Homebrew is required for --runtime homebrew" >&2
      exit 1
    fi
    if [[ ! -x "$HOMEBREW_CLI" ]] && ! command -v whisper-cli >/dev/null 2>&1; then
      brew install whisper-cpp
    fi
    runtime_cli="$(command -v whisper-cli || true)"
    if [[ -z "$runtime_cli" && -x "$HOMEBREW_CLI" ]]; then
      runtime_cli="$HOMEBREW_CLI"
    fi
    ;;
  auto)
    if command -v whisper-cli >/dev/null 2>&1; then
      runtime_cli="$(command -v whisper-cli)"
    elif [[ -x "$HOMEBREW_CLI" ]]; then
      runtime_cli="$HOMEBREW_CLI"
    elif [[ -x "$SOURCE_CLI" ]]; then
      runtime_cli="$SOURCE_CLI"
    fi
    ;;
  none)
    ;;
esac

if [[ -n "$runtime_cli" ]]; then
  echo
  echo "== Configure runtime =="
  plutil -replace whisperBinaryPath -string "$runtime_cli" "$CONFIG"
  echo "whisper-cli: $runtime_cli"
elif [[ "$RUNTIME_MODE" != "none" ]]; then
  echo
  echo "WARN no whisper-cli runtime found."
  echo "Install one with:"
  echo "  ./scripts/setup_source_install.sh --runtime homebrew"
  echo "or build vendored whisper.cpp with:"
  echo "  ./scripts/setup_source_install.sh --runtime source"
fi

if (( INSTALL_ALL_MODELS )); then
  echo
  echo "== Install all Whisper models =="
  YAPPYAPP_APP_SUPPORT="$APP_SUPPORT" ./scripts/install_model.sh --all
  MODEL_NAME="${MODEL_NAME:-large-v3-turbo}"
elif [[ -n "$MODEL_NAME" ]]; then
  echo
  echo "== Install Whisper model =="
  YAPPYAPP_APP_SUPPORT="$APP_SUPPORT" ./scripts/install_model.sh "$MODEL_NAME"
fi

if [[ -n "$MODEL_NAME" ]]; then
  if [[ -n "${YAPPYAPP_APP_SUPPORT_BASE:-}" ]]; then
    model_path="$APP_SUPPORT/models/ggml-$MODEL_NAME.bin"
  else
    # Literal token is persisted in config and expanded by the app at runtime.
    # shellcheck disable=SC2088
    model_path="~/Library/Application Support/YappYapp/models/ggml-$MODEL_NAME.bin"
  fi
  plutil -replace modelPath -string "$model_path" "$CONFIG"
  echo "selected model: $model_path"
fi

if (( RUN_DOCTOR )); then
  echo
  echo "== Doctor =="
  ./scripts/doctor.sh
fi

echo
echo "Source setup complete."
if [[ "$SDKROOT" != "$(yappyapp_sdk_default)" ]]; then
  echo "Run from source with: SDKROOT=\"$SDKROOT\" swift run YappYapp"
else
  echo "Run from source with: swift run YappYapp"
fi
echo "Package locally with: ./scripts/package_app.sh && open dist/YappYapp.app"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROVENANCE="$ROOT_DIR/docs/RELEASE_PROVENANCE.json"
MODEL_NAME="${YAPPYAPP_MODEL_NAME:-large-v3-turbo}"
APP_SUPPORT="${YAPPYAPP_APP_SUPPORT:-$HOME/Library/Application Support/YappYapp}"
MODEL_DIR="$APP_SUPPORT/models"
ALL_MODELS=(
  "large-v3-turbo"
  "large-v3"
  "medium"
  "small"
  "base"
  "tiny"
  "medium.en"
  "small.en"
  "base.en"
  "tiny.en"
)

if [[ ! -f "$PROVENANCE" ]]; then
  echo "error: release provenance is missing: $PROVENANCE" >&2
  echo "Refusing to download a Whisper model from an unpinned source." >&2
  exit 1
fi

WHISPER_MODEL_REV="$(plutil -extract model_sources.whisper.revision raw -o - "$PROVENANCE" 2>/dev/null || true)"
if [[ ! "$WHISPER_MODEL_REV" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: model_sources.whisper.revision is missing or invalid in $PROVENANCE" >&2
  echo "Refusing to download a Whisper model from an unpinned source." >&2
  exit 1
fi

print_supported_models() {
  printf "%s\n" "${ALL_MODELS[@]}"
}

is_supported_model() {
  local candidate="$1"
  local model

  for model in "${ALL_MODELS[@]}"; do
    if [[ "$candidate" == "$model" ]]; then
      return 0
    fi
  done

  return 1
}

validate_model_name() {
  local model_name="$1"

  if is_supported_model "$model_name"; then
    return 0
  fi

  echo "error: unsupported Whisper model '$model_name'." >&2
  echo "Supported models:" >&2
  print_supported_models | sed "s/^/  - /" >&2
  exit 1
}

expected_sha1() {
  case "$1" in
    large-v3-turbo) echo "4af2b29d7ec73d781377bfd1758ca957a807e941" ;;
    large-v3) echo "ad82bf6a9043ceed055076d0fd39f5f186ff8062" ;;
    medium) echo "fd9727b6e1217c2f614f9b698455c4ffd82463b4" ;;
    small) echo "55356645c2b361a969dfd0ef2c5a50d530afd8d5" ;;
    base) echo "465707469ff3a37a2b9b8d8f89f2f99de7299dac" ;;
    tiny) echo "bd577a113a864445d4c299885e0cb97d4ba92b5f" ;;
    medium.en) echo "8c30f0e44ce9560643ebd10bbe50cd20eafd3723" ;;
    small.en) echo "db8a495a91d927739e50b3fc1cc4c6b8f6c2d022" ;;
    base.en) echo "137c40403d78fd54d454da0f9bd998f78703390c" ;;
    tiny.en) echo "c78c86eb1a8faa21b369bcd33207cc90d64ae9df" ;;
    *) echo "" ;;
  esac
}

verify_model() {
  local model_name="$1"
  local model_path="$2"
  local expected
  local actual

  expected="$(expected_sha1 "$model_name")"
  if [[ -z "$expected" ]]; then
    echo "error: no checksum registered for '$model_name'." >&2
    echo "Refusing to install an unverified model through this helper." >&2
    return 1
  fi

  actual="$(shasum -a 1 "$model_path" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "Checksum mismatch for $(basename "$model_path")" >&2
    echo "expected: $expected" >&2
    echo "actual:   $actual" >&2
    return 1
  fi

  echo "Verified SHA-1: $actual"
}

download_model() {
  local model_name="$1"
  local model_path="$MODEL_DIR/ggml-$model_name.bin"
  local temp_path="$model_path.download"
  local model_url="https://huggingface.co/ggerganov/whisper.cpp/resolve/$WHISPER_MODEL_REV/ggml-$model_name.bin"

  validate_model_name "$model_name"
  mkdir -p "$MODEL_DIR"

  if [[ -f "$model_path" ]]; then
    echo "Model already exists: $model_path"
    verify_model "$model_name" "$model_path"
    ls -lh "$model_path"
    return 0
  fi

  echo "Downloading ggml-$model_name.bin to $temp_path"
  curl -L --fail --continue-at - --output "$temp_path" "$model_url"
  if ! verify_model "$model_name" "$temp_path"; then
    rm -f "$temp_path"
    exit 1
  fi
  mv "$temp_path" "$model_path"
  ls -lh "$model_path"
}

usage() {
  cat <<EOF
Usage:
  ./scripts/install_model.sh [model-name]
  ./scripts/install_model.sh --all
  ./scripts/install_model.sh --list

Examples:
	  ./scripts/install_model.sh
	  ./scripts/install_model.sh tiny.en
	  YAPPYAPP_MODEL_NAME=small ./scripts/install_model.sh

Supported models:
$(print_supported_models | sed "s/^/  - /")

Models install to:
  $MODEL_DIR
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
elif [[ "${1:-}" == "--list" ]]; then
  print_supported_models
elif [[ "${1:-}" == "--all" ]]; then
  for model in "${ALL_MODELS[@]}"; do
    download_model "$model"
  done
else
  if [[ -n "${1:-}" ]]; then
    MODEL_NAME="$1"
  fi
  download_model "$MODEL_NAME"
fi

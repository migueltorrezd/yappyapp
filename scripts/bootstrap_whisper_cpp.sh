#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/vendor"
WHISPER_DIR="$VENDOR_DIR/whisper.cpp"
APP_SUPPORT="$HOME/Library/Application Support/YappYapp"
MODEL_DIR="$APP_SUPPORT/models"
MODEL_NAME="${YAPPYAPP_MODEL_NAME:-large-v3-turbo}"
INSTALL_MODEL=1

usage() {
  cat <<EOF
Usage:
  ./scripts/bootstrap_whisper_cpp.sh [--model MODEL] [--skip-model]

Builds vendored whisper.cpp runtime helpers:
  vendor/whisper.cpp/build/bin/whisper-cli
  vendor/whisper.cpp/build/bin/whisper-server

By default it also installs the recommended Whisper model through
scripts/install_model.sh, which verifies the downloaded file checksum.

Options:
  --model MODEL   Whisper model name, e.g. large-v3-turbo, small, tiny.en
  --skip-model    Build runtime only; do not download model weights
  -h, --help      Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      MODEL_NAME="${2:-}"
      if [[ -z "$MODEL_NAME" ]]; then
        echo "error: --model requires a value" >&2
        exit 2
      fi
      shift 2
      ;;
    --skip-model)
      INSTALL_MODEL=0
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

mkdir -p "$VENDOR_DIR" "$MODEL_DIR"

# FIX whisper-pin: build the exact whisper.cpp revision the release pins in
# docs/RELEASE_PROVENANCE.json, not a moving upstream HEAD, so a local bootstrap
# reproduces the shipped runtime. Missing or malformed provenance fails closed.
PROVENANCE="$ROOT_DIR/docs/RELEASE_PROVENANCE.json"
if [[ ! -f "$PROVENANCE" ]]; then
  echo "error: release provenance is missing: $PROVENANCE" >&2
  echo "Refusing to clone or build whisper.cpp from an unpinned source." >&2
  exit 1
fi
WHISPER_REV="$(plutil -extract bundled_runtimes.0.revision raw -o - "$PROVENANCE" 2>/dev/null || true)"
if [[ ! "$WHISPER_REV" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: bundled_runtimes.0.revision is missing or invalid in $PROVENANCE" >&2
  echo "Refusing to clone or build whisper.cpp from an unpinned source." >&2
  exit 1
fi

# YA-11: YappYapp patches applied on top of the pinned revision. The
# whisper-server hardening patch drops the permissive CORS headers, the /load
# route and static file serving, and refuses any request carrying a browser
# Origin header.
PATCH_DIR="$ROOT_DIR/scripts/patches"
WHISPER_PATCHES=()
for patch in "$PATCH_DIR"/whisper-*.patch; do
  [[ -f "$patch" ]] && WHISPER_PATCHES+=("$patch")
done

if [[ ! -d "$WHISPER_DIR/.git" ]]; then
  git clone https://github.com/ggml-org/whisper.cpp.git "$WHISPER_DIR"
  git -C "$WHISPER_DIR" checkout --quiet "$WHISPER_REV"
  echo "Checked out pinned whisper.cpp revision $WHISPER_REV."
else
  current_rev="$(git -C "$WHISPER_DIR" rev-parse HEAD 2>/dev/null || true)"
  if [[ "$current_rev" != "$WHISPER_REV" ]]; then
    # Our own hardening patches are not "tracked changes" worth preserving:
    # take them off so the checkout can move, they go back on below.
    for patch in "${WHISPER_PATCHES[@]}"; do
      if git -C "$WHISPER_DIR" apply --reverse --check "$patch" >/dev/null 2>&1; then
        git -C "$WHISPER_DIR" apply --reverse "$patch"
      fi
    done
    if ! git -C "$WHISPER_DIR" diff --quiet || ! git -C "$WHISPER_DIR" diff --cached --quiet; then
      echo "error: existing vendor/whisper.cpp has tracked changes and is not at pinned revision $WHISPER_REV" >&2
      echo "       preserve or revert those changes before rebuilding the release runtime" >&2
      exit 1
    fi
    if ! git -C "$WHISPER_DIR" cat-file -e "$WHISPER_REV^{commit}" 2>/dev/null; then
      git -C "$WHISPER_DIR" fetch origin "$WHISPER_REV"
    fi
    git -C "$WHISPER_DIR" checkout --quiet "$WHISPER_REV"
    echo "Checked out pinned whisper.cpp revision $WHISPER_REV."
  fi
fi

# Idempotent: a patch that is already in place is skipped, one that no
# longer applies to the pinned revision stops the build.
for patch in "${WHISPER_PATCHES[@]}"; do
  name="$(basename "$patch")"
  if git -C "$WHISPER_DIR" apply --reverse --check "$patch" >/dev/null 2>&1; then
    echo "Patch already applied: $name"
  elif git -C "$WHISPER_DIR" apply --check "$patch" >/dev/null 2>&1; then
    git -C "$WHISPER_DIR" apply "$patch"
    echo "Applied patch: $name"
  else
    echo "error: $name does not apply to whisper.cpp $WHISPER_REV" >&2
    exit 1
  fi
done

cmake -S "$WHISPER_DIR" -B "$WHISPER_DIR/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON

cmake --build "$WHISPER_DIR/build" --config Release -j "$(sysctl -n hw.ncpu)" --target whisper-cli whisper-server

CLI_PATH="$WHISPER_DIR/build/bin/whisper-cli"
if [[ ! -x "$CLI_PATH" ]]; then
  echo "whisper-cli was not produced at $CLI_PATH" >&2
  exit 1
fi

if (( INSTALL_MODEL )); then
  "$ROOT_DIR/scripts/install_model.sh" "$MODEL_NAME"
else
  echo "Skipping model download. Install one later with: ./scripts/install_model.sh $MODEL_NAME"
fi

mkdir -p "$APP_SUPPORT"
if [[ ! -f "$APP_SUPPORT/config.json" ]]; then
  if (( INSTALL_MODEL )); then
    # Literal token is persisted in config and expanded by the app at runtime.
    # shellcheck disable=SC2088
    CONFIG_MODEL_PATH="~/Library/Application Support/YappYapp/models/ggml-$MODEL_NAME.bin"
  else
    CONFIG_MODEL_PATH="parakeet://ultra"
  fi
  cat > "$APP_SUPPORT/config.json" <<EOF
{
  "additionalPrompt" : "Company vocabulary and exact spellings may include product names, client names, internal tools, acronyms, and multilingual business terminology.",
  "language" : "auto",
  "maxRecordingSeconds" : 300,
  "modelPath" : "$CONFIG_MODEL_PATH",
  "pasteWhenFocusIsUnclear" : true,
  "allowModelDownloads" : true,
  "restoreClipboardAfterPaste" : true,
  "keepModelWarm" : true,
  "quietVoiceBoost" : true,
  "removeFillerWords" : false,
  "translateToEnglish" : false,
  "whisperBinaryPath" : "$CLI_PATH"
}
EOF
else
  echo "Config already exists at $APP_SUPPORT/config.json"
  echo "Set whisperBinaryPath to: $CLI_PATH"
  if (( INSTALL_MODEL )); then
    echo "Set modelPath to: ~/Library/Application Support/YappYapp/models/ggml-$MODEL_NAME.bin"
  fi
fi

echo "YappYapp bootstrap complete."
echo "whisper-cli: $CLI_PATH"
echo "model: $MODEL_DIR/ggml-$MODEL_NAME.bin"

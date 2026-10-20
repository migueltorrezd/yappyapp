#!/usr/bin/env bash
set -euo pipefail

# LLM-CLEANUP (YA-10): builds the llama.cpp runtime that YappYapp bundles for
# the optional on-device cleanup pass, so a DMG user needs neither Homebrew
# nor a terminal. The build is pinned to the release tag and commit recorded
# in docs/RELEASE_PROVENANCE.json and produces static, Metal-enabled, arm64
# helpers from the same source:
#
#   vendor/llama.cpp/build/bin/llama-completion
#   vendor/llama.cpp/build/bin/llama-server
#   vendor/llama.cpp/build/bin/llama-mtmd-cli
#
# llama-completion is the single-process completion tool: it reads the prompt,
# writes the reply to stdout and exits. It is the fallback when the warm
# server is not ready. llama-server keeps the cleanup model loaded between
# dictations so cleanup skips the per-run spawn and model load. The app binds
# it to 127.0.0.1 on a free port behind a per-launch random path prefix and
# turns its web UI off. The build turns HTTPS model downloads off and ships no
# prebuilt web UI, so neither helper can fetch anything from the network. They
# never download model weights; the app fetches the pinned GGUFs itself and
# verifies their checksums.
#
# QWEN3-ASR: llama-mtmd-cli is the one-shot audio helper for the Qwen3-ASR
# speech models (a model GGUF plus its audio projector). llama-server runs the
# same models warm with --mmproj. Audio support for Qwen3-ASR (the qwen3a
# projector) is in this pinned release.
#
# This script never touches ~/Library/Application Support/YappYapp.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/vendor"
LLAMA_DIR="$VENDOR_DIR/llama.cpp"
BUILD_DIR="$LLAMA_DIR/build"
PROVENANCE="$ROOT_DIR/docs/RELEASE_PROVENANCE.json"
TARGETS=(llama-completion llama-server llama-mtmd-cli)

usage() {
  cat <<EOF
Usage:
  ./scripts/bootstrap_llama_cpp.sh

Clones llama.cpp at the pinned release tag (if needed), checks the commit,
and builds:
  vendor/llama.cpp/build/bin/llama-completion
  vendor/llama.cpp/build/bin/llama-server
  vendor/llama.cpp/build/bin/llama-mtmd-cli

package_app.sh bundles and signs them when present.
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  "")
    ;;
  *)
    echo "error: unknown argument: $1" >&2
    usage >&2
    exit 2
    ;;
esac

if [[ ! -f "$PROVENANCE" ]]; then
  echo "error: release provenance is missing: $PROVENANCE" >&2
  echo "Refusing to clone or build llama.cpp from an unpinned source." >&2
  exit 1
fi

read_runtime_field() {
  ruby -rjson -e '
    manifest = JSON.parse(File.read(ARGV[0]))
    runtime = manifest.fetch("bundled_runtimes").find { |item| item.fetch("name") == "llama.cpp" }
    abort "llama.cpp runtime missing from provenance" unless runtime
    puts runtime.fetch(ARGV[1])
  ' "$PROVENANCE" "$1"
}

LLAMA_TAG="$(read_runtime_field tag 2>/dev/null || true)"
LLAMA_REV="$(read_runtime_field revision 2>/dev/null || true)"
if [[ ! "$LLAMA_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ || ! "$LLAMA_REV" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: the llama.cpp tag or revision is missing or invalid in $PROVENANCE" >&2
  echo "Refusing to clone or build llama.cpp from an unpinned source." >&2
  exit 1
fi

mkdir -p "$VENDOR_DIR"

if [[ ! -d "$LLAMA_DIR/.git" ]]; then
  git clone --quiet --filter=blob:none --branch "$LLAMA_TAG" --depth 1 \
    https://github.com/ggml-org/llama.cpp.git "$LLAMA_DIR"
fi

current_rev="$(git -C "$LLAMA_DIR" rev-parse HEAD 2>/dev/null || true)"
if [[ "$current_rev" != "$LLAMA_REV" ]]; then
  if ! git -C "$LLAMA_DIR" diff --quiet || ! git -C "$LLAMA_DIR" diff --cached --quiet; then
    echo "error: vendor/llama.cpp has tracked changes and is not at pinned revision $LLAMA_REV" >&2
    echo "       preserve or revert those changes before rebuilding the release runtime" >&2
    exit 1
  fi
  git -C "$LLAMA_DIR" fetch --quiet --depth 1 origin "refs/tags/$LLAMA_TAG:refs/tags/$LLAMA_TAG"
  git -C "$LLAMA_DIR" checkout --quiet "$LLAMA_TAG"
  current_rev="$(git -C "$LLAMA_DIR" rev-parse HEAD)"
fi

# The tag must still point at the commit the release pinned. A moved tag
# stops the build instead of silently shipping different code.
if [[ "$current_rev" != "$LLAMA_REV" ]]; then
  echo "error: llama.cpp $LLAMA_TAG resolves to $current_rev, expected $LLAMA_REV" >&2
  exit 1
fi
echo "Using pinned llama.cpp $LLAMA_TAG ($LLAMA_REV)."

# Static, Metal-enabled, portable arm64 build:
# - BUILD_SHARED_LIBS=OFF and GGML_METAL_EMBED_LIBRARY=ON give one
#   self-contained executable with the Metal shaders compiled in.
# - GGML_NATIVE=OFF keeps the CPU path portable across Apple Silicon Macs.
# - LLAMA_OPENSSL=OFF drops HTTPS model downloads from the helper.
# - LLAMA_USE_PREBUILT_UI=OFF keeps the build itself offline after the clone
#   and LLAMA_BUILD_UI=OFF leaves the server without a web UI.
# - LLAMA_BUILD_SERVER=ON adds llama-server; LLAMA_BUILD_APP stays OFF.
cmake -S "$LLAMA_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_NATIVE=OFF \
  -DLLAMA_OPENSSL=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_SERVER=ON \
  -DLLAMA_BUILD_APP=OFF \
  -DLLAMA_BUILD_UI=OFF \
  -DLLAMA_USE_PREBUILT_UI=OFF

cmake --build "$BUILD_DIR" --config Release -j "$(sysctl -n hw.ncpu)" --target "${TARGETS[@]}"

for TARGET in "${TARGETS[@]}"; do
  BIN_PATH="$BUILD_DIR/bin/$TARGET"
  if [[ ! -x "$BIN_PATH" ]]; then
    echo "error: $TARGET was not produced at $BIN_PATH" >&2
    exit 1
  fi

  # The helper must not depend on Homebrew or any other build-machine library.
  linked_libraries="$(otool -L "$BIN_PATH" | tail -n +2)"
  if grep -Ev '^[[:space:]]+(/usr/lib/|/System/Library/)' <<< "$linked_libraries" | grep -q .; then
    echo "error: $TARGET links a library outside the macOS system paths:" >&2
    otool -L "$BIN_PATH" >&2
    exit 1
  fi

  if [[ "$(lipo -archs "$BIN_PATH")" != "arm64" ]]; then
    echo "error: $TARGET is not a thin arm64 binary: $(lipo -archs "$BIN_PATH")" >&2
    exit 1
  fi
done

echo "llama.cpp bootstrap complete."
for TARGET in "${TARGETS[@]}"; do
  echo "$TARGET: $BUILD_DIR/bin/$TARGET"
done
echo "Next: ./scripts/update_runtime_provenance.sh to record its checksum."

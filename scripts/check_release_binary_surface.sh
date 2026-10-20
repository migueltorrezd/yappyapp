#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_EXEC="${YAPPYAPP_RELEASE_EXECUTABLE:-$ROOT_DIR/dist/YappYapp.app/Contents/MacOS/YappYapp}"

if [[ ! -x "$APP_EXEC" ]]; then
  echo "error: release executable missing or not executable: $APP_EXEC" >&2
  exit 1
fi

binary_strings="$(mktemp)"
cleanup() {
  rm -f "$binary_strings"
}
trap cleanup EXIT

strings -a "$APP_EXEC" > "$binary_strings"

banned_literals=(
  "--self-test"
  "--route-change-test"
  "--route-change-list-devices"
  "--prepare-support"
  "--accessibility-stale-status"
  "--setup-readiness-status"
  "--recording-smoke"
  "--transcription-smoke"
  "--paste-smoke"
  "--cmdv-smoke"
  "--llm-cleanup-smoke"
  "--render-gallery"
  "llmCleanup.input="
  "llmCleanup.output="
  "supportDirectory="
)

failures=0
for literal in "${banned_literals[@]}"; do
  if grep -Fq -- "$literal" "$binary_strings"; then
    echo "FAIL release executable exposes test-only literal: $literal" >&2
    failures=$((failures + 1))
  else
    echo "OK release executable excludes: $literal"
  fi
done

intended_diagnostics=(
  "--permissions-status"
  "--parakeet-cache-status"
)

for literal in "${intended_diagnostics[@]}"; do
  if grep -Fq -- "$literal" "$binary_strings"; then
    echo "OK release executable retains intended diagnostic: $literal"
  else
    echo "FAIL release executable is missing intended diagnostic: $literal" >&2
    failures=$((failures + 1))
  fi
done

# `--launch-smoke` is a short Swift string that release optimization can encode
# as an immediate value, so it is not reliably visible to `strings`. The release
# pipeline verifies that flag behaviorally in both launch_smoke.sh and
# launchservices_smoke.sh immediately after this static surface check.
echo "OK --launch-smoke is verified by packaged executable and LaunchServices smokes"

# LLM-CLEANUP (YA-10): the release bundles the pinned llama.cpp runtime so
# cleanup works without Homebrew. It must be a signed, hardened, arm64 helper
# that links only macOS system libraries and keeps no build-machine rpath.
# The same rules apply to llama-server, the warm cleanup helper, and to
# llama-mtmd-cli, the one-shot Qwen3-ASR audio helper.
# YAPPYAPP_ALLOW_MISSING_CLEANUP_RUNTIME=1 relaxes the presence check for
# local experiments only.
APP_BUNDLE="${APP_EXEC%/Contents/MacOS/*}"
check_llama_helper() {
  local name="$1"
  local helper="$APP_BUNDLE/Contents/Resources/bin/$name"
  if codesign --verify --strict "$helper" 2>/dev/null; then
    echo "OK bundled $name signature verifies"
  else
    echo "FAIL bundled $name is unsigned or its signature is broken" >&2
    failures=$((failures + 1))
  fi
  # Capture first: grep -q closing the pipe early would fail under pipefail.
  local signature
  signature="$(codesign -d --verbose=2 "$helper" 2>&1 || true)"
  if grep -Eq 'flags=.*runtime' <<< "$signature"; then
    echo "OK bundled $name uses the hardened runtime"
  else
    echo "FAIL bundled $name is not signed with the hardened runtime" >&2
    failures=$((failures + 1))
  fi
  if [[ "$(lipo -archs "$helper" 2>/dev/null)" == "arm64" ]]; then
    echo "OK bundled $name is arm64"
  else
    echo "FAIL bundled $name is not a thin arm64 binary" >&2
    failures=$((failures + 1))
  fi
  local libraries
  libraries="$(otool -L "$helper" | tail -n +2)"
  if grep -Ev '^[[:space:]]+(/usr/lib/|/System/Library/)' <<< "$libraries" | grep -q .; then
    echo "FAIL bundled $name links a library outside macOS system paths" >&2
    failures=$((failures + 1))
  else
    echo "OK bundled $name links only macOS system libraries"
  fi
  local load_commands
  load_commands="$(otool -l "$helper")"
  if grep -A2 'cmd LC_RPATH' <<< "$load_commands" | grep -E '^[[:space:]]+path ' | grep -Ev 'path (@executable_path|@loader_path|/usr/lib/swift)' | grep -q .; then
    echo "FAIL bundled $name keeps a build-machine rpath" >&2
    failures=$((failures + 1))
  else
    echo "OK bundled $name keeps no build-machine rpath"
  fi
}

LLAMA_HELPER="$APP_BUNDLE/Contents/Resources/bin/llama-completion"
LLAMA_SERVER="$APP_BUNDLE/Contents/Resources/bin/llama-server"
LLAMA_MTMD="$APP_BUNDLE/Contents/Resources/bin/llama-mtmd-cli"
if [[ -f "$LLAMA_HELPER" ]]; then
  check_llama_helper llama-completion
  # The warm cleanup server ships next to llama-completion, from the same
  # pinned source; a bundle with one and not the other is a packaging slip.
  if [[ -f "$LLAMA_SERVER" ]]; then
    check_llama_helper llama-server
  elif [[ "${YAPPYAPP_ALLOW_MISSING_CLEANUP_RUNTIME:-0}" == "1" ]]; then
    echo "OK llama-server not bundled (allowed by YAPPYAPP_ALLOW_MISSING_CLEANUP_RUNTIME)"
  else
    echo "FAIL release bundle has llama-completion but not llama-server: rerun scripts/bootstrap_llama_cpp.sh" >&2
    failures=$((failures + 1))
  fi
  # QWEN3-ASR: the one-shot audio helper ships from the same pinned source.
  if [[ -f "$LLAMA_MTMD" ]]; then
    check_llama_helper llama-mtmd-cli
  elif [[ "${YAPPYAPP_ALLOW_MISSING_CLEANUP_RUNTIME:-0}" == "1" ]]; then
    echo "OK llama-mtmd-cli not bundled (allowed by YAPPYAPP_ALLOW_MISSING_CLEANUP_RUNTIME)"
  else
    echo "FAIL release bundle has llama-completion but not llama-mtmd-cli: rerun scripts/bootstrap_llama_cpp.sh" >&2
    failures=$((failures + 1))
  fi
elif [[ "${YAPPYAPP_ALLOW_MISSING_CLEANUP_RUNTIME:-0}" == "1" ]]; then
  echo "OK llama-completion not bundled (allowed by YAPPYAPP_ALLOW_MISSING_CLEANUP_RUNTIME)"
else
  echo "FAIL release bundle is missing the LLM cleanup runtime: run scripts/bootstrap_llama_cpp.sh" >&2
  failures=$((failures + 1))
fi

if (( failures > 0 )); then
  echo "Release binary surface check failed with $failures failure(s)." >&2
  exit 1
fi

echo "Release binary diagnostic surface verified."

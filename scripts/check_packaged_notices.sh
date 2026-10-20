#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${YAPPYAPP_PACKAGED_APP_DIR:-$ROOT_DIR/dist/YappYapp.app}"
NOTICES_DIR="$APP_DIR/Contents/Resources/Notices"
THIRD_PARTY_LICENSES_DIR="$NOTICES_DIR/ThirdParty"

cd "$ROOT_DIR"

if [[ ! -d "$APP_DIR" ]]; then
  echo "error: packaged app missing: $APP_DIR" >&2
  exit 1
fi

if [[ ! -d "$NOTICES_DIR" ]]; then
  echo "error: packaged notices directory missing: $NOTICES_DIR" >&2
  exit 1
fi

failures=0

check_copy() {
  local source="$1"
  local bundled="$2"

  if [[ ! -s "$source" ]]; then
    echo "FAIL source notice missing or empty: $source" >&2
    failures=$((failures + 1))
    return
  fi

  if [[ ! -s "$bundled" ]]; then
    echo "FAIL bundled notice missing or empty: ${bundled#"$ROOT_DIR"/}" >&2
    failures=$((failures + 1))
    return
  fi

  if ! cmp -s "$source" "$bundled"; then
    echo "FAIL bundled notice drifted from source: ${bundled#"$ROOT_DIR"/}" >&2
    failures=$((failures + 1))
    return
  fi

  echo "OK ${bundled#"$ROOT_DIR"/}"
}

check_copy "LICENSE" "$NOTICES_DIR/LICENSE.txt"
check_copy "THIRD_PARTY_NOTICES.md" "$NOTICES_DIR/THIRD_PARTY_NOTICES.md"
check_copy "docs/RELEASE_PROVENANCE.json" "$NOTICES_DIR/RELEASE_PROVENANCE.json"
check_copy "vendor/whisper.cpp/LICENSE" "$THIRD_PARTY_LICENSES_DIR/whisper.cpp-LICENSE.txt"
# LLM-CLEANUP (YA-10): a bundled llama.cpp runtime must carry its license.
if [[ -e "$APP_DIR/Contents/Resources/bin/llama-completion" || -e "$APP_DIR/Contents/Resources/bin/llama-server" || -e "$APP_DIR/Contents/Resources/bin/llama-mtmd-cli" ]]; then
  check_copy "vendor/llama.cpp/LICENSE" "$THIRD_PARTY_LICENSES_DIR/llama.cpp-LICENSE.txt"
  if [[ -d "vendor/llama.cpp/licenses" ]]; then
    for license_file in vendor/llama.cpp/licenses/*; do
      [[ -f "$license_file" ]] || continue
      check_copy "$license_file" "$THIRD_PARTY_LICENSES_DIR/llama.cpp-$(basename "$license_file").txt"
    done
  else
    echo "FAIL source notices missing: vendor/llama.cpp/licenses/" >&2
    failures=$((failures + 1))
  fi
fi
# cpp-httplib and nlohmann/json ship inside whisper-server and the llama.cpp helpers.
if [[ -e "$APP_DIR/Contents/Resources/bin/whisper-server" || -e "$APP_DIR/Contents/Resources/bin/llama-completion" || -e "$APP_DIR/Contents/Resources/bin/llama-server" || -e "$APP_DIR/Contents/Resources/bin/llama-mtmd-cli" ]]; then
  check_copy "packaging/notices/cpp-httplib-LICENSE.txt" "$THIRD_PARTY_LICENSES_DIR/cpp-httplib-LICENSE.txt"
  check_copy "packaging/notices/nlohmann-json-LICENSE.txt" "$THIRD_PARTY_LICENSES_DIR/nlohmann-json-LICENSE.txt"
fi
check_copy ".build/checkouts/FluidAudio/LICENSE" "$THIRD_PARTY_LICENSES_DIR/FluidAudio-LICENSE.txt"
check_copy ".build/checkouts/FluidAudio/ThirdPartyLicenses/fastcluster-LICENSE.md" "$THIRD_PARTY_LICENSES_DIR/FluidAudio-fastcluster-LICENSE.md"
check_copy ".build/checkouts/FluidAudio/ThirdPartyLicenses/vbx-LICENSE.md" "$THIRD_PARTY_LICENSES_DIR/FluidAudio-vbx-LICENSE.md"
check_copy ".build/checkouts/Sparkle/LICENSE" "$THIRD_PARTY_LICENSES_DIR/Sparkle-LICENSE.txt"

if [[ ! -s "$NOTICES_DIR/README.txt" ]]; then
  echo "FAIL bundled notices README missing or empty" >&2
  failures=$((failures + 1))
elif ! grep -q "Keep these notices with redistributed app bundles and DMGs" "$NOTICES_DIR/README.txt"; then
  echo "FAIL bundled notices README is missing redistribution guidance" >&2
  failures=$((failures + 1))
elif ! grep -q "ThirdParty/" "$NOTICES_DIR/README.txt"; then
  echo "FAIL bundled notices README is missing third-party license guidance" >&2
  failures=$((failures + 1))
else
  echo "OK ${NOTICES_DIR#"$ROOT_DIR"/}/README.txt"
fi

if [[ "$failures" -gt 0 ]]; then
  echo "Packaged notices check failed with $failures failure(s)." >&2
  exit 1
fi

echo "Packaged notices verified."

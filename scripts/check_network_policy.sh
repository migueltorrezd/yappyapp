#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/YappYapp.app"

cd "$ROOT_DIR"

errors=0

fail() {
  errors=$((errors + 1))
  printf "FAIL %s\n" "$1" >&2
}

ok() {
  printf "OK   %s\n" "$1"
}

print_block() {
  local title="$1"
  local body="$2"

  printf "%s\n" "$title" >&2
  printf "%s\n" "$body" | sed 's/^/  /' >&2
}

runtime_swift_files=()
while IFS= read -r -d '' path; do
  case "$path" in
    */SelfTests.swift|*/SelfTests+*.swift) ;;
    *) runtime_swift_files+=("$path") ;;
  esac
done < <(find Sources/YappYapp -name '*.swift' -print0)

# FIX netpolicy-scan: a missing or broken source scanner must fail loudly, never
# pass vacuously. The old form `rg ... 2>/dev/null || true` swallowed exit 127
# (rg absent), so the check printed OK having scanned nothing. Prefer a real
# ripgrep binary; fall back to `grep -E` with equivalent patterns (\b works on
# both BSD and GNU grep). Both tools use exit 1 = no matches, exit >1 = real
# error, so scan_sources treats only exit 1 as clean and aborts on anything
# worse.
if command -v rg >/dev/null 2>&1; then
  scan_sources() {
    local out status=0
    out="$(rg -nH "$@" 2>/dev/null)" || status=$?
    if (( status > 1 )); then
      echo "error: source scan failed (rg exit $status): rg -nH $*" >&2
      exit 2
    fi
    printf '%s' "$out"
  }
else
  scan_sources() {
    local pattern="$1"
    shift
    local out status=0
    out="$(grep -nHE "$pattern" "$@" 2>/dev/null)" || status=$?
    if (( status > 1 )); then
      echo "error: source scan failed (grep exit $status): grep -nHE $pattern ..." >&2
      exit 2
    fi
    printf '%s' "$out"
  }
fi

url_matches="$(scan_sources 'https?://' "${runtime_swift_files[@]}")"
bad_urls=""
while IFS= read -r match; do
  [[ -z "$match" ]] && continue
  case "$match" in
    *ModelDownloadManager.swift:*'https://huggingface.co/ggerganov/whisper.cpp/resolve/\(whisperModelRevision)/\(option.filename)'*) ;;
    *ParakeetModelDistribution.swift:*'private static let huggingFaceOrigin = "https://huggingface.co"'*) ;;
    *LLMCleaner.swift:*'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/\(LLMCleanerPinnedRevision)/qwen2.5-1.5b-instruct-q4_k_m.gguf'*) ;;
    *Translation.swift:*'https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/\(HyMT2FastPinnedRevision)/Hy-MT2-1.8B-Q4_K_M.gguf'*) ;;
    *Translation.swift:*'https://huggingface.co/tencent/Hy-MT2-7B-GGUF/resolve/\(HyMT2BestPinnedRevision)/Hy-MT2-7B-Q4_K_M.gguf'*) ;;
    *Qwen3ASR.swift:*'URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(filename)")!'*) ;;
    *WhisperServerController.swift:*'http://127.0.0.1'*) ;;
    # HELP > MADE BY: user-clicked links handed to the default browser only.
    *DeveloperLinks.swift:*'static let youTube = URL(string: "https://www.youtube.com/@migueltorrezai")!'*) ;;
    *DeveloperLinks.swift:*'static let linkedIn = URL(string: "https://www.linkedin.com/in/miguel-torrez")!'*) ;;
    *) bad_urls+="${bad_urls:+$'\n'}$match" ;;
  esac
done <<< "$url_matches"
if [[ -n "$bad_urls" ]]; then
  fail "runtime Swift contains unexpected external URL literals"
  print_block "Unexpected URL literals:" "$bad_urls"
else
  ok "runtime Swift URL literals are limited to approved local/model-download endpoints"
fi

# FIX netpolicy-scan: capture the scan into a variable FIRST so scan_sources'
# exit-2 abort propagates (a direct assignment fails the script under set -e),
# instead of running it on the left of a `... | grep ... || true` pipeline where
# the abort is swallowed and the check could pass having scanned nothing.
urlsession_matches="$(scan_sources '\bURLSession\b' "${runtime_swift_files[@]}")"
bad_urlsession="$(
  printf "%s\n" "$urlsession_matches" |
    grep -Ev 'WhisperServerController\.swift|LlamaServerController\.swift|ModelDownloadManager\.swift|ParakeetModelDistribution\.swift|LLMCleaner\.swift|CleanupModelDownloader\.swift' || true
)"
if [[ -n "$bad_urlsession" ]]; then
  fail "runtime Swift uses URLSession outside approved local server/model downloader files"
  print_block "Unexpected URLSession uses:" "$bad_urlsession"
else
  ok "URLSession use is limited to the local Whisper and llama servers and model downloads"
fi

bad_network_apis="$(
  scan_sources '\b(NWConnection|NWListener|NWPathMonitor|NetService|CFSocket|CFStreamCreatePairWithSocketToHost)\b' "${runtime_swift_files[@]}"
)"
if [[ -n "$bad_network_apis" ]]; then
  fail "runtime Swift contains unexpected lower-level network APIs"
  print_block "Unexpected network APIs:" "$bad_network_apis"
else
  ok "no unexpected lower-level network APIs found in runtime Swift"
fi

if ! grep -Eq '\bURLSession\b|dataTask|URLRequest' Sources/YappYapp/DeveloperLinks.swift &&
  grep -Fq 'NSWorkspace.shared.open(url)' Sources/YappYapp/DeveloperLinks.swift; then
  ok "developer links only open in the default browser on a click"
else
  fail "developer links must only be opened with NSWorkspace, never fetched"
fi

if grep -Fq 'static let host = "127.0.0.1"' Sources/YappYapp/WhisperServerController.swift &&
  grep -Fq 'URL(string: "http://127.0.0.1:\(port)\(requestPath)")!' Sources/YappYapp/WhisperServerController.swift &&
  grep -Fq '"--host", host' Sources/YappYapp/WhisperServerController.swift; then
  ok "warm Whisper server is pinned to 127.0.0.1"
else
  fail "warm Whisper server is not visibly pinned to 127.0.0.1"
fi

# LLM-CLEANUP-WARM, TRANSLATION-WARM, QWEN3-ASR-WARM: every warm
# llama-server (one controller type) binds the same loopback host, sits
# behind the same per-launch endpoint, and never serves the web UI.
if grep -Fq '"--host", WhisperServerController.host' Sources/YappYapp/LlamaServerController.swift &&
  grep -Fq 'WhisperServerEndpoint.random(port: port)' Sources/YappYapp/LlamaServerController.swift &&
  grep -Fq '"--no-webui"' Sources/YappYapp/LlamaServerController.swift &&
  ! grep -Eq 'https?://' Sources/YappYapp/LlamaServerController.swift; then
  ok "warm cleanup and translation servers are pinned to 127.0.0.1 with no web UI"
else
  fail "warm cleanup and translation servers are not visibly pinned to 127.0.0.1 without a web UI"
fi

if grep -Fq 'guard state.config.allowModelDownloads else' Sources/YappYapp/AppDelegate.swift &&
  grep -Fq 'downloadsAllowed: downloadsAllowed' Sources/YappYapp/AppDelegate.swift &&
  grep -Fq 'guard downloadsAllowed else' Sources/YappYapp/ParakeetTranscriber.swift &&
  grep -Fq 'try await ModelDownloadManager.downloadParakeet' Sources/YappYapp/ParakeetTranscriber.swift; then
  ok "Whisper and verified Parakeet downloads are gated by allowModelDownloads"
else
  fail "model-download gating is not visibly enforced for Whisper and verified Parakeet downloads"
fi

if grep -Fq 'ModelHub.offlineMode = true' Sources/YappYapp/ParakeetTranscriber.swift &&
  grep -Fq 'guard ModelDownloadManager.isVerifiedParakeetCache(variant: variant) else' Sources/YappYapp/ParakeetTranscriber.swift &&
  grep -Fq 'let models = try await AsrModels.load(' Sources/YappYapp/ParakeetTranscriber.swift &&
  grep -Fq 'guard selectedModelInstalled else' Sources/YappYapp/FirstRunReadiness.swift &&
  grep -Fq 'if !isCached {' Sources/YappYapp/AppDelegate.swift &&
  ! grep -Eq 'AsrModels\.(download|downloadAndLoad)' Sources/YappYapp/ParakeetTranscriber.swift; then
  ok "FluidAudio stays offline and loads only YappYapp-verified Parakeet caches"
else
  fail "Parakeet inference can bypass the verified YappYapp downloader/cache invariant"
fi

if grep -Fq 'private static let huggingFaceOrigin = "https://huggingface.co"' Sources/YappYapp/ParakeetModelDistribution.swift &&
  grep -Fq '\(huggingFaceOrigin)/api/models/\(plan.repo.remotePath)/tree/\(plan.revision)' Sources/YappYapp/ParakeetModelDistribution.swift &&
  grep -Fq '\(huggingFaceOrigin)/\(plan.repo.remotePath)/resolve/\(plan.revision)' Sources/YappYapp/ParakeetModelDistribution.swift &&
  ! grep -Eq 'ModelRegistry\.(baseURL|apiModels)|REGISTRY_URL|MODEL_REGISTRY_URL' Sources/YappYapp/ParakeetModelDistribution.swift; then
  ok "verified Parakeet downloads are fixed to the Hugging Face origin"
else
  fail "verified Parakeet downloads can inherit a mutable or environment-controlled registry origin"
fi

if ! grep -Eq 'Authorization|Bearer[[:space:]]|HF_TOKEN|HUGGING_FACE_HUB_TOKEN|HUGGINGFACE_TOKEN' \
  Sources/YappYapp/ModelDownloadManager.swift Sources/YappYapp/ParakeetModelDistribution.swift; then
  ok "public Parakeet downloads do not read or forward ambient Hugging Face credentials"
else
  fail "verified public Parakeet downloader reads or attaches ambient credentials"
fi

whisper_revision="$(
  ruby -rjson -e '
    manifest = JSON.parse(File.read("docs/RELEASE_PROVENANCE.json"))
    model = manifest.fetch("huggingface_model_cards").fetch("models").find { |item| item.fetch("repo") == "ggerganov/whisper.cpp" }
    puts model.fetch("revision")
  '
)"
# The literal variable reference must remain in install_model.sh.
# shellcheck disable=SC2016
if grep -Fq "static let whisperModelRevision = \"$whisper_revision\"" Sources/YappYapp/ModelDownloadManager.swift &&
  grep -Fq 'https://huggingface.co/ggerganov/whisper.cpp/resolve/\(whisperModelRevision)/' Sources/YappYapp/ModelDownloadManager.swift &&
  grep -Fq 'model_sources.whisper.revision' scripts/install_model.sh &&
  grep -Fq 'resolve/$WHISPER_MODEL_REV/' scripts/install_model.sh &&
  ! grep -Fq 'resolve/main/' scripts/install_model.sh; then
  ok "in-app and script Whisper model downloads use the provenance-pinned Hugging Face revision"
else
  fail "a Whisper model download source is not pinned to release provenance"
fi

if grep -Eq '^let LLMCleanerPinnedRevision = "[0-9a-f]{40}"$' Sources/YappYapp/LLMCleaner.swift &&
  grep -Eq '^let LLMCleanerPinnedSHA1 = "[0-9a-f]{40}"$' Sources/YappYapp/LLMCleaner.swift &&
  grep -Fq 'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/\(LLMCleanerPinnedRevision)/' Sources/YappYapp/LLMCleaner.swift; then
  ok "optional LLM cleanup download is revision- and checksum-pinned"
else
  fail "optional LLM cleanup download is not visibly revision- and checksum-pinned"
fi

# LLM-CLEANUP (YA-10): the cleanup downloader fetches only the pinned model
# URL, installs only after the SHA-1 check, and never starts without the
# runtime or with downloads off.
if grep -Fq 'init(source: URL = LLMCleaner.model.downloadURL)' Sources/YappYapp/CleanupModelDownloader.swift &&
  grep -Fq 'session.downloadTask(with: source)' Sources/YappYapp/CleanupModelDownloader.swift &&
  grep -Fq 'throw CleanupModelError.checksumMismatch' Sources/YappYapp/CleanupModelStore.swift &&
  grep -Fq 'guard config.cleanup.usesModel, config.allowModelDownloads, !cleanupVerifyInFlight,' Sources/YappYapp/AppDelegate.swift &&
  grep -Fq 'LLMCleaner.isRuntimeAvailable(configured: config.llamaBinaryPath) else {' Sources/YappYapp/AppDelegate.swift; then
  ok "cleanup model download is pinned, checksum-verified, and gated by the runtime and allowModelDownloads"
else
  fail "cleanup model download is not visibly pinned, verified, and gated"
fi

# TRANSLATION (round 2): translation models download only from their pinned
# revision, install only after the SHA-256 check, and never start without the
# runtime or with downloads off.
if grep -Eq '^let HyMT2FastPinnedRevision = "[0-9a-f]{40}"$' Sources/YappYapp/Translation.swift &&
  grep -Eq '^let HyMT2BestPinnedRevision = "[0-9a-f]{40}"$' Sources/YappYapp/Translation.swift &&
  grep -Eq '^let HyMT2FastPinnedSHA256 = "[0-9a-f]{64}"$' Sources/YappYapp/Translation.swift &&
  grep -Eq '^let HyMT2BestPinnedSHA256 = "[0-9a-f]{64}"$' Sources/YappYapp/Translation.swift &&
  grep -Fq 'CleanupModelDownloader(source: download.url)' Sources/YappYapp/TranslationCoordinator.swift &&
  grep -Fq 'config.allowModelDownloads, !verifying.contains(id),' Sources/YappYapp/TranslationCoordinator.swift &&
  grep -Fq 'LLMCleaner.isRuntimeAvailable(configured: config.llamaBinaryPath) else {' Sources/YappYapp/TranslationCoordinator.swift &&
  grep -Fq 'sha1: ModelIntegrity.sha256Hex(for:)' Sources/YappYapp/Translator.swift; then
  ok "translation model downloads are pinned, SHA-256 verified, and gated by the runtime and allowModelDownloads"
else
  fail "translation model downloads are not visibly pinned, verified, and gated"
fi

# QWEN3-ASR: the speech model files download only from their fixed ggml-org
# repositories at a pinned revision, install only after the SHA-256 check,
# and never start without the bundled runtime or with downloads off. The warm
# speech server is the same LlamaServerController (loopback, no web UI) as
# cleanup and translation.
if grep -Eq '^let Qwen3ASRSmallPinnedRevision = "[0-9a-f]{40}"$' Sources/YappYapp/Qwen3ASR.swift &&
  grep -Eq '^let Qwen3ASRLargePinnedRevision = "[0-9a-f]{40}"$' Sources/YappYapp/Qwen3ASR.swift &&
  grep -Fq 'case .small: "ggml-org/Qwen3-ASR-0.6B-GGUF"' Sources/YappYapp/Qwen3ASR.swift &&
  grep -Fq 'case .large: "ggml-org/Qwen3-ASR-1.7B-GGUF"' Sources/YappYapp/Qwen3ASR.swift &&
  [[ "$(grep -Ec 'sha256: "[0-9a-f]{64}"' Sources/YappYapp/Qwen3ASR.swift)" == "4" ]] &&
  grep -Fq 'CleanupModelDownloader(source: file.url)' Sources/YappYapp/Qwen3ASRDownloads.swift &&
  grep -Fq 'try Qwen3ASRModelStore.install(file, downloadedFile: staged)' Sources/YappYapp/Qwen3ASRDownloads.swift &&
  grep -Fq 'sha1: ModelIntegrity.sha256Hex(for:)' Sources/YappYapp/Qwen3ASR.swift &&
  grep -Fq 'if option.engine == .qwen3asr, !Qwen3ASRRuntime.isAvailable(configuredLlamaBinary: state.config.llamaBinaryPath) {' Sources/YappYapp/AppDelegate.swift &&
  grep -Fq 'static let speech = LlamaServerController(' Sources/YappYapp/Qwen3ASRServer.swift &&
  ! grep -Eq 'https?://' Sources/YappYapp/Qwen3ASRServer.swift Sources/YappYapp/Qwen3ASRDownloads.swift; then
  ok "Qwen3-ASR downloads are pinned, SHA-256 verified, and gated; its warm server is the loopback llama-server"
else
  fail "Qwen3-ASR downloads or its warm server are not visibly pinned, verified, gated and loopback-only"
fi

check_entitlements_file() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    return
  fi

  if grep -Eq 'com\.apple\.security\.network\.(client|server)' "$file"; then
    fail "$file declares a network entitlement"
  else
    ok "$file has no network entitlement"
  fi
}

# YappYapp.entitlements is the only entitlements file the app ships; the copy
# under vendor/whisper.cpp/examples belongs to an upstream demo we do not build.
check_entitlements_file "YappYapp.entitlements"

if [[ -d "$APP_DIR" ]]; then
  entitlements_file="$(mktemp)"
  if codesign -d --entitlements :- "$APP_DIR" >"$entitlements_file" 2>/dev/null; then
    if grep -Eq 'com\.apple\.security\.network\.(client|server)' "$entitlements_file"; then
      fail "packaged app signature includes a network entitlement"
    else
      ok "packaged app signature has no network entitlement"
    fi
  else
    # An existing bundle we cannot read entitlements from is an unverifiable
    # state, not a clean one: fail instead of claiming OK by "skipping".
    fail "codesign could not read entitlements from existing bundle $APP_DIR"
  fi
  rm -f "$entitlements_file"
else
  ok "packaged app missing; packaged entitlement scan skipped"
fi

if grep -Fq "no cloud transcription" README.md &&
  grep -Fq "Runtime network posture" docs/PACKAGING.md &&
  grep -Fq "Do not market the app as network-free" docs/MODEL_DISTRIBUTION.md; then
  ok "public docs describe the local-first network posture and caveats"
else
  fail "public docs are missing local-first network posture/caveat language"
fi

if (( errors > 0 )); then
  echo "Network policy check failed." >&2
  exit 1
fi

echo "Network policy verified."

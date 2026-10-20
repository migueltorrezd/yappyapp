#!/usr/bin/env bash
# End-to-end dictation pipeline test: synthesized speech -> 16 kHz mono WAV
# (the exact format the recorder produces) -> whisper transcription -> text
# assertion. Exercises the same binary and model the packaged app ships.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFERRED_MODELS_DIR="$HOME/Library/Application Support/YappYapp/models"
LEGACY_MODELS_DIR="$HOME/Library/Application Support/YappYappLegacy/models"
MODEL_DIRS=("$PREFERRED_MODELS_DIR")
if [[ "$LEGACY_MODELS_DIR" != "$PREFERRED_MODELS_DIR" ]]; then
  MODEL_DIRS+=("$LEGACY_MODELS_DIR")
fi

CLI="$ROOT/dist/YappYapp.app/Contents/Resources/bin/whisper-cli"
if [[ ! -x "$CLI" ]]; then
  CLI="$(command -v whisper-cli || true)"
fi

# Smallest installed model keeps the test fast; accuracy is not the point.
MODEL=""
for models_dir in "${MODEL_DIRS[@]}"; do
  for candidate in ggml-tiny.en.bin ggml-tiny.bin ggml-base.en.bin ggml-base.bin ggml-small.en.bin ggml-small.bin ggml-medium.bin ggml-large-v3-turbo.bin ggml-large-v3.bin; do
    if [[ -f "$models_dir/$candidate" ]]; then
      MODEL="$models_dir/$candidate"
      break 2
    fi
  done
done

if [[ -z "${CLI:-}" || ! -x "$CLI" ]]; then
  echo "E2E SKIPPED: whisper-cli not found (package the app first)"
  exit 0
fi
if [[ -z "$MODEL" ]]; then
  echo "E2E SKIPPED: no whisper model installed in $PREFERRED_MODELS_DIR or $LEGACY_MODELS_DIR"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say -o "$TMP/speech.aiff" "The quick brown fox jumps over the lazy dog"
SPEECH_BYTES="$(afinfo "$TMP/speech.aiff" 2>/dev/null | awk '/audio bytes:/ {print $3; exit}')"
if [[ -z "$SPEECH_BYTES" || "$SPEECH_BYTES" == "0" ]]; then
  echo "E2E SKIPPED: speech synthesis produced empty audio"
  exit 0
fi
afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/speech.aiff" "$TMP/speech.wav"

echo "Model: $(basename "$MODEL")"
TRANSCRIPT="$("$CLI" -m "$MODEL" -f "$TMP/speech.wav" -nt -l en -ng 2>/dev/null | tr -d '\n' | sed 's/^ *//')"
echo "Transcript: $TRANSCRIPT"

# Tiny models can confuse "quick" with "click" on synthetic speech. The E2E
# assertion is about pipeline health, so anchor on the more stable phrase.
if echo "$TRANSCRIPT" | grep -qi "brown fox" && echo "$TRANSCRIPT" | grep -qi "lazy dog"; then
  echo "E2E PASSED: pipeline transcribed synthesized speech"
else
  echo "E2E FAILED: transcript did not contain the expected phrase anchors"
  exit 1
fi

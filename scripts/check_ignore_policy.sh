#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f .gitignore ]]; then
  echo "error: .gitignore is missing" >&2
  exit 1
fi

errors=0

must_ignore=(
  ".build/workspace-state.json"
  ".swiftpm/configuration/registries.json"
  "DerivedData/YappYapp/Build/log.txt"
  "dist/YappYapp.dmg"
  "vendor/whisper.cpp/build/bin/whisper-cli"
  ".tmp/smoke/audio.wav"
  ".DS_Store"
  "Scratch.swp"
  "YappYapp.app/Contents/Info.plist"
  "YappYapp.dmg"
  "YappYapp.app.zip"
  "models/ggml-large-v3-turbo.bin"
  "models/local-model.gguf"
  "models/parakeet.mlpackage/Data/model.mlmodel"
  "models/parakeet.mlmodelc/coremldata.bin"
  "models/export.onnx"
  "models/weights.safetensors"
  "recordings/dictation.wav"
  "recordings/dictation.m4a"
  "recordings/dictation.flac"
  "notes/yappyapp-transcript.txt"
  "notes/yappyapp-transcript.json"
  "notes/yappyapp-transcript.csv"
  "server.log"
  "support-report-local.md"
  "manual-qa-report-local.md"
)

must_not_ignore=(
  "Package.swift"
  "README.md"
  "Sources/YappYapp/AppDelegate.swift"
  "docs/INSTALL.md"
  "docs/RELEASE_PROVENANCE.json"
  "scripts/check_ignore_policy.sh"
)

for path in "${must_ignore[@]}"; do
  if git check-ignore -q -- "$path"; then
    echo "OK ignored: $path"
  else
    echo "error: expected .gitignore to ignore $path" >&2
    errors=$((errors + 1))
  fi
done

for path in "${must_not_ignore[@]}"; do
  if git check-ignore -q -- "$path"; then
    echo "error: expected .gitignore to allow source file $path" >&2
    errors=$((errors + 1))
  else
    echo "OK trackable: $path"
  fi
done

if (( errors > 0 )); then
  echo "Ignore policy check failed." >&2
  exit 1
fi

echo "Ignore policy verified."

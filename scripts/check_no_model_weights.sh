#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/YappYapp.app"

cd "$ROOT_DIR"

weight_regex='(^|/)(ggml-[^/]+\.bin|[^/]+\.(gguf|safetensors|onnx|tflite|pt|pth|ckpt|mlmodel|mlmodelc|mlpackage|coremlmodel|nemo))$'
errors=0

print_matches() {
  local title="$1"
  shift

  printf "%s\n" "$title" >&2
  for match in "$@"; do
    printf "  - %s\n" "$match" >&2
  done
}

source_matches=()
while IFS= read -r -d '' path; do
  lower_path="$(printf "%s" "$path" | tr "[:upper:]" "[:lower:]")"
  if [[ "$lower_path" =~ $weight_regex ]]; then
    source_matches+=("$path")
  fi
done < <(git ls-files -z --cached --others --exclude-standard)

if (( ${#source_matches[@]} > 0 )); then
  errors=$((errors + 1))
  print_matches "Source-tree files look like model weights:" "${source_matches[@]}"
else
  echo "OK no source-tree model weight files found."
fi

if [[ -d "$APP_DIR" ]]; then
  packaged_matches=()
  while IFS= read -r -d '' path; do
    rel_path="${path#"$ROOT_DIR"/}"
    lower_path="$(printf "%s" "$rel_path" | tr "[:upper:]" "[:lower:]")"
    if [[ "$lower_path" =~ $weight_regex ]]; then
      packaged_matches+=("$rel_path")
    fi
  done < <(find "$APP_DIR" -print0)

  if (( ${#packaged_matches[@]} > 0 )); then
    errors=$((errors + 1))
    print_matches "Packaged app contains files that look like model weights:" "${packaged_matches[@]}"
  else
    echo "OK packaged app contains no model weight files."
  fi

  models_dir="$APP_DIR/Contents/Resources/models"
  model_dir_entries=()
  if [[ -d "$models_dir" ]]; then
    while IFS= read -r -d '' path; do
      if [[ "$path" != "$models_dir" ]]; then
        model_dir_entries+=("${path#"$ROOT_DIR"/}")
      fi
    done < <(find "$models_dir" -print0)
  fi

  if (( ${#model_dir_entries[@]} > 0 )); then
    errors=$((errors + 1))
    print_matches "Packaged app has a non-empty Resources/models directory:" "${model_dir_entries[@]}"
  else
    echo "OK packaged app does not ship a populated Resources/models directory."
  fi
else
  echo "SKIP packaged app scan: dist/YappYapp.app does not exist yet."
fi

if ! grep -q "Do not commit Whisper or Parakeet model weights" docs/MODEL_DISTRIBUTION.md; then
  errors=$((errors + 1))
  echo "Model distribution policy is missing the no-committed-weights rule." >&2
fi

if ! grep -q "does not bundle Whisper or Parakeet model weights" docs/MODEL_DISTRIBUTION.md; then
  errors=$((errors + 1))
  echo "Model distribution policy is missing the no-bundled-weights rule." >&2
fi

if (( errors > 0 )); then
  echo "Model weight policy check failed." >&2
  exit 1
fi

echo "Model weight policy verified."

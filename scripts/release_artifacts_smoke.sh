#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
CHECKSUMS_PATH="$DIST_DIR/checksums.txt"
DMG_PATH="$DIST_DIR/YappYapp.dmg"
APP_ZIP_PATH="$DIST_DIR/YappYapp.app.zip"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "FAIL $*" >&2
  exit 1
}

cd "$ROOT_DIR"

echo "== Release artifacts smoke =="

[[ -s "$DMG_PATH" ]] || fail "missing or empty artifact: dist/YappYapp.dmg"
[[ -s "$APP_ZIP_PATH" ]] || fail "missing or empty artifact: dist/YappYapp.app.zip"
[[ -s "$CHECKSUMS_PATH" ]] || fail "missing or empty artifact: dist/checksums.txt"

grep -Eq "^[0-9a-f]{64}  YappYapp\.dmg$" "$CHECKSUMS_PATH" \
  || fail "dist/checksums.txt is missing YappYapp.dmg SHA-256"
grep -Eq "^[0-9a-f]{64}  YappYapp\.app\.zip$" "$CHECKSUMS_PATH" \
  || fail "dist/checksums.txt is missing YappYapp.app.zip SHA-256"

(
  cd "$DIST_DIR"
  shasum -a 256 -c "$(basename "$CHECKSUMS_PATH")"
)
echo "OK release artifact checksums verify"

ditto -x -k "$APP_ZIP_PATH" "$TMP_DIR"

APP_DIR="$TMP_DIR/YappYapp.app"
APP_EXEC="$APP_DIR/Contents/MacOS/YappYapp"

[[ -d "$APP_DIR" ]] || fail "YappYapp.app missing from app zip"
[[ -x "$APP_EXEC" ]] || fail "app zip executable missing or not executable"

bundle_id="$(plutil -extract CFBundleIdentifier raw "$APP_DIR/Contents/Info.plist")"
bundle_name="$(plutil -extract CFBundleName raw "$APP_DIR/Contents/Info.plist")"
if [[ "$bundle_id" != "app.yappyapp.YappYapp" ]]; then
  fail "unexpected app zip bundle identifier: $bundle_id"
fi
if [[ "$bundle_name" != "YappYapp" ]]; then
  fail "unexpected app zip bundle name: $bundle_name"
fi
echo "OK app zip bundle identity: $bundle_id / $bundle_name"

codesign --verify --deep --strict --verbose=2 "$APP_DIR" >/dev/null
echo "OK app zip code signature verifies"

YAPPYAPP_PACKAGED_APP_DIR="$APP_DIR" ./scripts/check_packaged_notices.sh

weight_regex='(^|/)(ggml-[^/]+\.bin|[^/]+\.(gguf|safetensors|onnx|tflite|pt|pth|ckpt|mlmodel|mlmodelc|mlpackage|coremlmodel|nemo))$'
model_weight_matches=()
while IFS= read -r -d '' path; do
  rel_path="${path#"$TMP_DIR"/}"
  lower_path="$(printf "%s" "$rel_path" | tr "[:upper:]" "[:lower:]")"
  if [[ "$lower_path" =~ $weight_regex ]]; then
    model_weight_matches+=("$rel_path")
  fi
done < <(find "$APP_DIR" -print0)

if (( ${#model_weight_matches[@]} > 0 )); then
  printf "App zip contains files that look like model weights:\n" >&2
  for match in "${model_weight_matches[@]}"; do
    printf "  - %s\n" "$match" >&2
  done
  exit 1
fi
echo "OK app zip contains no model weight files"

echo "Release artifacts smoke passed."

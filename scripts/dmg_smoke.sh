#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG_PATH="$ROOT_DIR/dist/YappYapp.dmg"
MOUNT_PARENT="$(mktemp -d)"
MOUNT_DIR="$MOUNT_PARENT/YappYapp"
ATTACHED=0

cleanup() {
  if [[ "$ATTACHED" -eq 1 ]]; then
    hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || \
      hdiutil detach "$MOUNT_DIR" -force -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$MOUNT_PARENT"
}
trap cleanup EXIT

fail() {
  echo "FAIL $*" >&2
  exit 1
}

cd "$ROOT_DIR"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "error: DMG missing: $DMG_PATH" >&2
  exit 1
fi

echo "== DMG smoke =="
hdiutil verify "$DMG_PATH" -quiet
echo "OK hdiutil verifies DMG"

mkdir -p "$MOUNT_DIR"
hdiutil attach "$DMG_PATH" -mountpoint "$MOUNT_DIR" -nobrowse -readonly -quiet
ATTACHED=1

APP_DIR="$MOUNT_DIR/YappYapp.app"
APP_EXEC="$APP_DIR/Contents/MacOS/YappYapp"
APPLICATIONS_LINK="$MOUNT_DIR/Applications"

[[ -d "$APP_DIR" ]] || fail "YappYapp.app missing from mounted DMG"
[[ -x "$APP_EXEC" ]] || fail "packaged executable missing from mounted DMG"
[[ -L "$APPLICATIONS_LINK" ]] || fail "Applications symlink missing from mounted DMG"
[[ "$(readlink "$APPLICATIONS_LINK")" == "/Applications" ]] || fail "Applications symlink does not point to /Applications"

bundle_id="$(plutil -extract CFBundleIdentifier raw "$APP_DIR/Contents/Info.plist")"
bundle_name="$(plutil -extract CFBundleName raw "$APP_DIR/Contents/Info.plist")"
if [[ "$bundle_id" != "app.yappyapp.YappYapp" ]]; then
  fail "unexpected mounted bundle identifier: $bundle_id"
fi
if [[ "$bundle_name" != "YappYapp" ]]; then
  fail "unexpected mounted bundle name: $bundle_name"
fi
echo "OK mounted bundle identity: $bundle_id / $bundle_name"

codesign --verify --deep --strict --verbose=2 "$APP_DIR" >/dev/null
echo "OK mounted app code signature verifies"

YAPPYAPP_PACKAGED_APP_DIR="$APP_DIR" ./scripts/check_packaged_notices.sh

weight_regex='(^|/)(ggml-[^/]+\.bin|[^/]+\.(gguf|safetensors|onnx|tflite|pt|pth|ckpt|mlmodel|mlmodelc|mlpackage|coremlmodel|nemo))$'
model_weight_matches=()
while IFS= read -r -d '' path; do
  rel_path="${path#"$MOUNT_DIR"/}"
  lower_path="$(printf "%s" "$rel_path" | tr "[:upper:]" "[:lower:]")"
  if [[ "$lower_path" =~ $weight_regex ]]; then
    model_weight_matches+=("$rel_path")
  fi
done < <(find "$APP_DIR" -print0)

if (( ${#model_weight_matches[@]} > 0 )); then
  printf "Mounted DMG app contains files that look like model weights:\n" >&2
  for match in "${model_weight_matches[@]}"; do
    printf "  - %s\n" "$match" >&2
  done
  exit 1
fi
echo "OK mounted app contains no model weight files"

echo "DMG smoke passed."

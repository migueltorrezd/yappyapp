#!/usr/bin/env bash
set -euo pipefail

APP_SUPPORT_BASE="${YAPPYAPP_APP_SUPPORT_BASE:-$HOME/Library/Application Support}"
APP_SUPPORT="$APP_SUPPORT_BASE/YappYapp"
FILES=("config.json" "glossary.json" "snippets.json" "stats.json")
FORCE=0
OUTPUT=""

usage() {
  cat <<EOF
Usage:
  ./scripts/export_settings.sh [--force] OUTPUT.zip

Exports YappYapp settings/state files into a zip archive:
  - config.json
  - glossary.json
  - snippets.json, when present
  - stats.json, when present

It intentionally excludes models, audio, transcripts, logs, and temporary files.

Environment:
  YAPPYAPP_APP_SUPPORT_BASE  Override Application Support base for tests/admin use.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$OUTPUT" ]]; then
        echo "error: only one output path is allowed" >&2
        usage >&2
        exit 2
      fi
      OUTPUT="$1"
      shift
      ;;
  esac
done

if [[ -z "$OUTPUT" ]]; then
  usage >&2
  exit 2
fi

if [[ ! -d "$APP_SUPPORT" ]]; then
  echo "error: YappYapp support folder does not exist: $APP_SUPPORT" >&2
  exit 1
fi

if [[ -e "$OUTPUT" && "$FORCE" -ne 1 ]]; then
  echo "error: output already exists: $OUTPUT" >&2
  echo "       pass --force to replace it" >&2
  exit 1
fi

output_parent="$(dirname "$OUTPUT")"
mkdir -p "$output_parent"

TMP_DIR="$(mktemp -d)"
EXPORT_DIR="$TMP_DIR/YappYapp-settings"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$EXPORT_DIR"

included=()
for file in "${FILES[@]}"; do
  source_path="$APP_SUPPORT/$file"
  if [[ -f "$source_path" ]]; then
    plutil -convert json -o /dev/null -- "$source_path" >/dev/null 2>&1 \
      || { echo "error: $source_path is not valid JSON" >&2; exit 1; }
    cp "$source_path" "$EXPORT_DIR/$file"
    included+=("$file")
  fi
done

if (( ${#included[@]} == 0 )); then
  echo "error: no exportable settings files found in $APP_SUPPORT" >&2
  exit 1
fi

{
  printf "YappYapp settings export\n"
  printf "created_utc=%s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf "source_support=%s\n" "$APP_SUPPORT"
  printf "included_files=%s\n" "$(IFS=,; printf "%s" "${included[*]}")"
  printf "excluded=models,audio,transcripts,logs,temporary files\n"
} > "$EXPORT_DIR/MANIFEST.txt"

rm -f "$OUTPUT"
ditto -c -k --keepParent "$EXPORT_DIR" "$OUTPUT"

echo "Exported YappYapp settings:"
for file in "${included[@]}"; do
  echo "  - $file"
done
echo "Archive: $OUTPUT"

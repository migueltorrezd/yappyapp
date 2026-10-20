#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SUPPORT_BASE="${YAPPYAPP_APP_SUPPORT_BASE:-$HOME/Library/Application Support}"
APP_SUPPORT="$APP_SUPPORT_BASE/YappYapp"
FILES=("config.json" "glossary.json" "snippets.json" "stats.json")
APPLY=0
ARCHIVE=""

usage() {
  cat <<EOF
Usage:
  ./scripts/import_settings.sh BACKUP.zip
  ./scripts/import_settings.sh --apply BACKUP.zip

Dry-runs by default. With --apply, imports only:
  - config.json
  - glossary.json
  - snippets.json, when present
  - stats.json, when present

Before applying, the script exports the current settings to:
  ~/Library/Application Support/YappYapp/settings-backups/

It never imports models, audio, transcripts, logs, or temporary files.

Environment:
  YAPPYAPP_APP_SUPPORT_BASE  Override Application Support base for tests/admin use.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      APPLY=1
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
      if [[ -n "$ARCHIVE" ]]; then
        echo "error: only one archive path is allowed" >&2
        usage >&2
        exit 2
      fi
      ARCHIVE="$1"
      shift
      ;;
  esac
done

if [[ -z "$ARCHIVE" ]]; then
  usage >&2
  exit 2
fi

if [[ ! -f "$ARCHIVE" ]]; then
  echo "error: backup archive not found: $ARCHIVE" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
EXTRACT_DIR="$TMP_DIR/extracted"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$EXTRACT_DIR"
ditto -x -k "$ARCHIVE" "$EXTRACT_DIR"

SOURCE_DIR="$EXTRACT_DIR/YappYapp-settings"
if [[ ! -d "$SOURCE_DIR" ]]; then
  if [[ -f "$EXTRACT_DIR/config.json" || -f "$EXTRACT_DIR/glossary.json" || -f "$EXTRACT_DIR/snippets.json" || -f "$EXTRACT_DIR/stats.json" ]]; then
    SOURCE_DIR="$EXTRACT_DIR"
  else
    echo "error: archive does not contain a YappYapp-settings folder or supported settings files" >&2
    exit 1
  fi
fi

included=()
for file in "${FILES[@]}"; do
  source_path="$SOURCE_DIR/$file"
  if [[ -f "$source_path" ]]; then
    plutil -convert json -o /dev/null -- "$source_path" >/dev/null 2>&1 \
      || { echo "error: archive file is not valid JSON: $file" >&2; exit 1; }
    included+=("$file")
  fi
done

if (( ${#included[@]} == 0 )); then
  echo "error: archive contains no supported settings files" >&2
  exit 1
fi

echo "YappYapp settings import"
echo "Archive: $ARCHIVE"
echo "Destination: $APP_SUPPORT"
echo "Files:"
for file in "${included[@]}"; do
  echo "  - $file"
done

if (( APPLY == 0 )); then
  echo
  echo "Dry run only. Re-run with --apply to import these files."
  exit 0
fi

mkdir -p "$APP_SUPPORT"

current_count=0
for file in "${FILES[@]}"; do
  [[ -f "$APP_SUPPORT/$file" ]] && current_count=$((current_count + 1))
done

if (( current_count > 0 )); then
  backup_dir="$APP_SUPPORT/settings-backups"
  mkdir -p "$backup_dir"
  backup_path="$backup_dir/yappyapp-settings-before-import-$(date -u +"%Y%m%dT%H%M%SZ").zip"
  "$ROOT_DIR/scripts/export_settings.sh" --force "$backup_path" >/dev/null
  echo "Existing settings backed up to: $backup_path"
fi

for file in "${included[@]}"; do
  cp "$SOURCE_DIR/$file" "$APP_SUPPORT/$file"
done

echo "Imported YappYapp settings."
echo "Restart YappYapp for all changes to take effect."

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SUPPORT_BASE="${YAPPYAPP_APP_SUPPORT_BASE:-$HOME/Library/Application Support}"
APP_SUPPORT="$APP_SUPPORT_BASE/YappYapp"
APPLY=0
INCLUDE_MODELS=0
INCLUDE_BACKUPS=0
BACKUP_PATH=""

usage() {
  cat <<EOF
Usage:
  ./scripts/reset_app_data.sh [options]

Dry-runs by default. With --apply, deletes selected YappYapp Application
Support files. The app bundle itself is not removed.

Default reset targets:
  - config.json
  - glossary.json
  - snippets.json
  - stats.json
  - server.log
  - launch-smoke-ok

Options:
  --apply            Actually delete the listed targets.
  --include-models   Also delete the local models/ directory.
  --include-backups  Also delete settings-backups/.
  --backup PATH.zip  Export config/glossary/stats to PATH.zip before deleting.
  -h, --help         Show this help.

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
    --include-models)
      INCLUDE_MODELS=1
      shift
      ;;
    --include-backups)
      INCLUDE_BACKUPS=1
      shift
      ;;
    --backup)
      BACKUP_PATH="${2:-}"
      if [[ -z "$BACKUP_PATH" ]]; then
        echo "error: --backup requires a path" >&2
        exit 2
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

candidate_targets=(
  "$APP_SUPPORT/config.json"
  "$APP_SUPPORT/glossary.json"
  "$APP_SUPPORT/snippets.json"
  "$APP_SUPPORT/stats.json"
  "$APP_SUPPORT/server.log"
  "$APP_SUPPORT/launch-smoke-ok"
)

if (( INCLUDE_MODELS )); then
  candidate_targets+=("$APP_SUPPORT/models")
fi

if (( INCLUDE_BACKUPS )); then
  candidate_targets+=("$APP_SUPPORT/settings-backups")
fi

targets=()
for target in "${candidate_targets[@]}"; do
  if [[ -e "$target" ]]; then
    targets+=("$target")
  fi
done

echo "YappYapp app-data reset"
echo "Support folder: $APP_SUPPORT"
echo

if (( ${#targets[@]} == 0 )); then
  echo "No reset targets exist."
  exit 0
fi

echo "Targets:"
for target in "${targets[@]}"; do
  echo "  - $target"
done

if [[ -n "$BACKUP_PATH" ]]; then
  echo
  echo "Backup archive: $BACKUP_PATH"
fi

if (( APPLY == 0 )); then
  echo
  echo "Dry run only. Re-run with --apply to delete these exact targets."
  exit 0
fi

if [[ -n "$BACKUP_PATH" ]]; then
  if "$ROOT_DIR/scripts/export_settings.sh" --force "$BACKUP_PATH" >/dev/null; then
    echo "Backed up settings to: $BACKUP_PATH"
  else
    echo "error: backup failed; refusing to reset app data" >&2
    exit 1
  fi
fi

for target in "${targets[@]}"; do
  rm -rf "$target"
done

echo
echo "Deleted:"
for target in "${targets[@]}"; do
  echo "  - $target"
done

echo "Restart YappYapp to recreate default config and glossary files."

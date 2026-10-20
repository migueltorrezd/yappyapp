#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<EOF
Usage:
  ./scripts/route_change_test.sh
  ./scripts/route_change_test.sh --list-devices
  ./scripts/route_change_test.sh --run

Default mode is safe: it lists input devices and does not record audio or change
the system default input device.

Use --run only during manual QA. The live test records audio, flips the system
default input device when two inputs are available, restores the original input,
and exercises the shipped capture-session route-change recovery path.
EOF
}

MODE="list"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list-devices)
      MODE="list"
      shift
      ;;
    --run)
      MODE="run"
      shift
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

if [[ "$MODE" == "list" ]]; then
  echo "== Route-change device inventory =="
  swift run YappYapp --route-change-list-devices
  exit 0
fi

echo "== Route-change crash harness =="
echo "This live test records audio, flips the system default input device when two"
echo "inputs are available, restores the original input, and exercises the shipped"
echo "capture-session route-change recovery path."
echo
echo "It may trigger the microphone permission prompt. Run it only during manual QA,"
echo "not inside unattended CI."
echo

swift run YappYapp --route-change-test

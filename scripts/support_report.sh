#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/YappYapp.app"
CHECKSUMS_PATH="$ROOT_DIR/dist/checksums.txt"

redact_stream() {
  awk -v home="$HOME" '
    {
      while (home != "" && (i = index($0, home)) > 0) {
        $0 = substr($0, 1, i - 1) "~" substr($0, i + length(home))
      }
      gsub(/\/Users\/[^\/[:space:]]+/, "/Users/<user>")
      print
    }
  '
}

capture_cmd() {
  local title="$1"
  shift
  local output
  local status

  output="$("$@" 2>&1)"
  status=$?

  printf "## %s\n\n" "$title"
  printf "Exit status: %s\n\n" "$status"
  printf "\`\`\`text\n"
  printf "%s\n" "$output" | redact_stream
  printf "\`\`\`\n\n"
}

print_value() {
  local label="$1"
  local value="$2"
  printf -- "- %s: %s\n" "$label" "$value" | redact_stream
}

plist_value() {
  local key="$1"
  if [[ -d "$APP_DIR" ]]; then
    plutil -extract "$key" raw "$APP_DIR/Contents/Info.plist" 2>/dev/null || printf "missing"
  else
    printf "app not packaged"
  fi
}

command_path_or_missing() {
  command -v "$1" 2>/dev/null || printf "missing"
}

printf "# YappYapp Support Report\n\n"
printf "This report is designed for GitHub issues. It does not include audio files, transcripts, glossary entries, config contents, or app logs.\n\n"

printf "## Generated\n\n"
print_value "UTC time" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
print_value "Working tree" "$ROOT_DIR"
if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  print_value "Git commit" "$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf "unknown")"
  print_value "Git dirty files" "$(git -C "$ROOT_DIR" status --short -- . 2>/dev/null | wc -l | tr -d " ")"
else
  print_value "Git commit" "not a git checkout"
fi
printf "\n"

printf "## System\n\n"
print_value "macOS" "$(sw_vers -productVersion 2>/dev/null || printf "unknown")"
print_value "Architecture" "$(uname -m 2>/dev/null || printf "unknown")"
print_value "Swift" "$(xcrun --find swift 2>/dev/null || printf "missing")"
print_value "Homebrew" "$(command_path_or_missing brew)"
print_value "cmake" "$(command_path_or_missing cmake)"
print_value "whisper-cli" "$(command_path_or_missing whisper-cli)"
print_value "whisper-server" "$(command_path_or_missing whisper-server)"
printf "\n"

printf "## Packaged App\n\n"
print_value "App path" "$APP_DIR"
print_value "Bundle name" "$(plist_value CFBundleName)"
print_value "Bundle identifier" "$(plist_value CFBundleIdentifier)"
print_value "Bundle version" "$(plist_value CFBundleVersion)"
print_value "Short version" "$(plist_value CFBundleShortVersionString)"
if [[ -f "$CHECKSUMS_PATH" ]]; then
  printf "\n### Checksums\n\n"
  printf "\`\`\`text\n"
  cat "$CHECKSUMS_PATH" | redact_stream
  printf "\`\`\`\n"
fi
printf "\n"

if [[ -d "$APP_DIR" ]]; then
  capture_cmd "Code Signature" codesign -dv --verbose=2 "$APP_DIR"
  capture_cmd "Gatekeeper Assessment" spctl --assess --type execute --verbose=4 "$APP_DIR"
fi

capture_cmd "Running Process" pgrep -fl "[Y]appYapp.app/Contents/MacOS/YappYapp"
capture_cmd "Doctor" "$ROOT_DIR/scripts/doctor.sh"

if [[ -x "$ROOT_DIR/scripts/check_ignore_policy.sh" ]]; then
  capture_cmd "Ignore Policy" "$ROOT_DIR/scripts/check_ignore_policy.sh"
fi

if [[ -x "$ROOT_DIR/scripts/check_privacy_artifacts.sh" ]]; then
  capture_cmd "Privacy Artifact Policy" "$ROOT_DIR/scripts/check_privacy_artifacts.sh"
fi

if [[ -x "$ROOT_DIR/scripts/check_network_policy.sh" ]]; then
  capture_cmd "Network Policy" "$ROOT_DIR/scripts/check_network_policy.sh"
fi

# SUPPORT (YA-44): crash report names and dates only, same as the in-app
# report. The files themselves are never read or attached.
printf "## Recent Crash Reports\n\n"
crash_dir="$HOME/Library/Logs/DiagnosticReports"
crash_list=""
if [[ -d "$crash_dir" ]]; then
  crash_list="$(find "$crash_dir" -maxdepth 1 -type f \( -iname 'yappyapp*.ips' -o -iname 'yappyapp*.crash' \) -mtime -30 -print 2>/dev/null \
    | while IFS= read -r path; do
        printf "%s\t%s\n" "$(stat -f %m "$path")" "$path"
      done | sort -rn | head -n 10 \
    | while IFS=$'\t' read -r mtime path; do
        printf -- "- %s (%s)\n" "$(basename "$path")" "$(date -u -r "$mtime" +"%Y-%m-%dT%H:%M:%SZ")"
      done)"
fi
if [[ -n "$crash_list" ]]; then
  printf "%s\n" "$crash_list" | redact_stream
else
  printf "None in the last 30 days.\n"
fi
printf "\n"

printf "## Before Posting\n\n"
printf -- "- [ ] I reviewed this report and removed anything I consider private.\n"
printf -- "- [ ] I did not attach audio recordings, transcripts, glossary files, config files, or app logs unless a maintainer explicitly requested them.\n"

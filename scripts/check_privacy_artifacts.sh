#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/YappYapp.app"

cd "$ROOT_DIR"

artifact_regex='(^|/)([^/]+\.(wav|wave|aif|aiff|caf|mp3|m4a|flac|ogg)|[^/]*transcript[^/]*\.(txt|json|csv))$'
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
  if [[ "$lower_path" =~ $artifact_regex ]]; then
    source_matches+=("$path")
  fi
done < <(git ls-files -z --cached --others --exclude-standard)

if (( ${#source_matches[@]} > 0 )); then
  errors=$((errors + 1))
  print_matches "Source-tree files look like recorded audio or transcript artifacts:" "${source_matches[@]}"
else
  echo "OK no source-tree audio/transcript artifacts found."
fi

if [[ -d "$APP_DIR" ]]; then
  packaged_matches=()
  while IFS= read -r -d '' path; do
    rel_path="${path#"$ROOT_DIR"/}"
    lower_path="$(printf "%s" "$rel_path" | tr "[:upper:]" "[:lower:]")"
    if [[ "$lower_path" =~ $artifact_regex ]]; then
      packaged_matches+=("$rel_path")
    fi
  done < <(find "$APP_DIR" -type f -print0)

  if (( ${#packaged_matches[@]} > 0 )); then
    errors=$((errors + 1))
    print_matches "Packaged app contains recorded audio or transcript artifacts:" "${packaged_matches[@]}"
  else
    echo "OK packaged app contains no recorded audio/transcript artifacts."
  fi
else
  echo "SKIP packaged app scan: dist/YappYapp.app does not exist yet."
fi

if ! grep -q "self.recorder.cleanup(audioURL)" Sources/YappYapp/AppDelegate.swift; then
  errors=$((errors + 1))
  echo "AppDelegate no longer shows cleanup for recorded audio URLs." >&2
fi

if ! awk '
  /Task \{/ { in_task = 1 }
  in_task && /defer \{/ { in_defer = 1 }
  in_defer && /self\.recorder\.cleanup\(audioURL\)/ { found = 1 }
  END { exit found ? 0 : 1 }
' Sources/YappYapp/AppDelegate.swift; then
  errors=$((errors + 1))
  echo "Recorded audio cleanup is not visibly protected by a Task defer block." >&2
fi

if ! grep -q "removeItem(at: transcriptURL)" Sources/YappYapp/WhisperTranscriber.swift; then
  errors=$((errors + 1))
  echo "WhisperTranscriber no longer removes temporary transcript files after reading them." >&2
fi

if ! grep -q "In-memory only" Sources/YappYapp/YappYappState.swift; then
  errors=$((errors + 1))
  echo "YappYappState is missing the in-memory transcript-history privacy note." >&2
fi

if ! grep -q "no transcript history" README.md; then
  errors=$((errors + 1))
  echo "README is missing the no transcript history privacy claim." >&2
fi

if ! grep -q "temporary audio is deleted" README.md; then
  errors=$((errors + 1))
  echo "README is missing the temporary audio deletion privacy claim." >&2
fi

if ! grep -q "NSMicrophoneUsageDescription" scripts/package_app.sh ||
  ! grep -q "records your voice locally" scripts/package_app.sh ||
  ! grep -q "on this Mac" scripts/package_app.sh; then
  errors=$((errors + 1))
  echo "Package Info.plist template is missing a local-first microphone usage description." >&2
fi

if [[ -d "$APP_DIR" ]]; then
  microphone_usage="$(
    plutil -extract NSMicrophoneUsageDescription raw "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
  )"
  if [[ -z "$microphone_usage" ]]; then
    errors=$((errors + 1))
    echo "Packaged app is missing NSMicrophoneUsageDescription." >&2
  elif [[ "$microphone_usage" != *"records your voice locally"* || "$microphone_usage" != *"on this Mac"* ]]; then
    errors=$((errors + 1))
    echo "Packaged app microphone usage description does not explain local dictation clearly: $microphone_usage" >&2
  else
    echo "OK packaged app has a local-first microphone usage description."
  fi
fi

if (( errors > 0 )); then
  echo "Privacy artifact policy check failed." >&2
  exit 1
fi

echo "Privacy artifact policy verified."

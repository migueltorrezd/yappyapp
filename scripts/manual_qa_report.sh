#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/YappYapp.app"
DMG_PATH="$ROOT_DIR/dist/YappYapp.dmg"
CHECKSUMS_PATH="$ROOT_DIR/dist/checksums.txt"
RUN_LAUNCHSERVICES_SMOKE=0

usage() {
  cat <<'EOF'
Usage: scripts/manual_qa_report.sh [--run-launchservices-smoke]

Print a markdown manual QA report template with release-candidate context
pre-filled. Redirect it to a release artifact when you are ready to complete
manual QA, for example:

  ./scripts/manual_qa_report.sh --run-launchservices-smoke > dist/manual-qa-report.md
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --run-launchservices-smoke)
      RUN_LAUNCHSERVICES_SMOKE=1
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
  shift
done

cd "$ROOT_DIR"

capture() {
  "$@" 2>&1 || true
}

plist_value() {
  local key="$1"
  local plist="$APP_DIR/Contents/Info.plist"
  if [[ -f "$plist" ]]; then
    plutil -extract "$key" raw "$plist" 2>/dev/null || printf "missing"
  else
    printf "missing"
  fi
}

yes_no_path() {
  if [[ -e "$1" ]]; then
    printf "yes"
  else
    printf "no"
  fi
}

xattr_value() {
  local path="$1"
  if [[ -e "$path" ]]; then
    xattr -p com.apple.quarantine "$path" 2>/dev/null || printf "not set"
  else
    printf "missing"
  fi
}

macos_version="$(sw_vers -productVersion 2>/dev/null || printf "unknown")"
macos_build="$(sw_vers -buildVersion 2>/dev/null || printf "unknown")"
arch="$(uname -m)"
generated_at="$(date -u "+%Y-%m-%dT%H:%M:%SZ")"
bundle_id="$(plist_value CFBundleIdentifier)"
bundle_name="$(plist_value CFBundleName)"
short_version="$(plist_value CFBundleShortVersionString)"
bundle_version="$(plist_value CFBundleVersion)"

codesign_verify="$(capture codesign --verify --deep --strict --verbose=2 "$APP_DIR")"
codesign_details="$(capture codesign -dv --verbose=4 "$APP_DIR")"
signature="$(printf "%s\n" "$codesign_details" | sed -n 's/^Signature=//p' | head -n 1)"
team_id="$(printf "%s\n" "$codesign_details" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
authorities="$(printf "%s\n" "$codesign_details" | sed -n 's/^Authority=//p' | paste -sd ', ' -)"
if [[ -z "$signature" ]]; then signature="unknown"; fi
if [[ -z "$team_id" ]]; then team_id="unknown"; fi
if [[ -z "$authorities" ]]; then authorities="none"; fi

app_spctl="$(capture spctl -a -vv -t open "$APP_DIR")"
dmg_spctl="$(capture spctl -a -vv -t open "$DMG_PATH")"
app_stapler="$(capture xcrun stapler validate "$APP_DIR")"
dmg_stapler="$(capture xcrun stapler validate "$DMG_PATH")"
notarization_preflight="$(capture ./scripts/notarization_preflight.sh)"
ignore_policy="$(capture ./scripts/check_ignore_policy.sh)"
model_weight_policy="$(capture ./scripts/check_no_model_weights.sh)"
privacy_artifact_policy="$(capture ./scripts/check_privacy_artifacts.sh)"
network_policy="$(capture ./scripts/check_network_policy.sh)"
app_quarantine="$(xattr_value "$APP_DIR")"
dmg_quarantine="$(xattr_value "$DMG_PATH")"

running_process="$(pgrep -fl "[Y]appYapp.app/Contents/MacOS/YappYapp" || true)"
if [[ -z "$running_process" ]]; then running_process="not running"; fi

support_dir="$HOME/Library/Application Support/YappYapp"
legacy_support_dir="$HOME/Library/Application Support/YappYappLegacy"
models_dir="$support_dir/models"
legacy_models_dir="$legacy_support_dir/models"
model_count=0
if [[ -d "$models_dir" ]]; then
  model_count="$(find "$models_dir" -type f -name 'ggml-*.bin' | wc -l | tr -d ' ')"
elif [[ -d "$legacy_models_dir" ]]; then
  model_count="$(find "$legacy_models_dir" -type f -name 'ggml-*.bin' | wc -l | tr -d ' ')"
fi

launchservices_status="not run"
launchservices_output=""
if (( RUN_LAUNCHSERVICES_SMOKE == 1 )); then
  if launchservices_output="$(./scripts/launchservices_smoke.sh 2>&1)"; then
    launchservices_status="passed"
  else
    launchservices_status="failed"
  fi
fi

cat <<EOF
# YappYapp Manual QA Report

Generated: \`$generated_at\`

This report is a release-candidate evidence template. It is not complete until
a tester fills every checkbox and records the hardware, macOS account type, and
permission behavior observed on a clean user account or second Mac.

## Candidate Context

- App exists: \`$(yes_no_path "$APP_DIR")\`
- DMG exists: \`$(yes_no_path "$DMG_PATH")\`
- App path: \`$APP_DIR\`
- DMG path: \`$DMG_PATH\`
- Bundle name: \`$bundle_name\`
- Bundle identifier: \`$bundle_id\`
- Version: \`$short_version ($bundle_version)\`
- macOS: \`$macos_version ($macos_build)\`
- Architecture: \`$arch\`
- Running process: \`$running_process\`
- YappYapp support folder exists: \`$(yes_no_path "$support_dir")\`
- Previous support folder exists: \`$(yes_no_path "$legacy_support_dir")\`
- Local Whisper model count in active user support: \`$model_count\`

## Signing And Gatekeeper Context

- Code signature: \`$signature\`
- Team identifier: \`$team_id\`
- Authority chain: \`$authorities\`
- App quarantine attribute: \`$app_quarantine\`
- DMG quarantine attribute: \`$dmg_quarantine\`
- LaunchServices smoke: \`$launchservices_status\`

### codesign --verify

\`\`\`text
$(printf "%s\n" "$codesign_verify")
\`\`\`

### spctl App Assessment

\`\`\`text
$(printf "%s\n" "$app_spctl")
\`\`\`

### spctl DMG Assessment

\`\`\`text
$(printf "%s\n" "$dmg_spctl")
\`\`\`

### stapler App Validation

\`\`\`text
$(printf "%s\n" "$app_stapler")
\`\`\`

### stapler DMG Validation

\`\`\`text
$(printf "%s\n" "$dmg_stapler")
\`\`\`

### Notarization Preflight

\`\`\`text
$(printf "%s\n" "$notarization_preflight")
\`\`\`

EOF

if (( RUN_LAUNCHSERVICES_SMOKE == 1 )); then
  cat <<EOF
### LaunchServices Smoke Output

\`\`\`text
$(printf "%s\n" "$launchservices_output")
\`\`\`

EOF
fi

cat <<EOF
## Checksums

\`\`\`text
$(if [[ -f "$CHECKSUMS_PATH" ]]; then cat "$CHECKSUMS_PATH"; else printf "missing %s" "$CHECKSUMS_PATH"; fi)
\`\`\`

## Ignore Policy

\`\`\`text
$(printf "%s\n" "$ignore_policy")
\`\`\`

## Model Weight Policy

\`\`\`text
$(printf "%s\n" "$model_weight_policy")
\`\`\`

## Privacy Artifact Policy

\`\`\`text
$(printf "%s\n" "$privacy_artifact_policy")
\`\`\`

## Network Policy

\`\`\`text
$(printf "%s\n" "$network_policy")
\`\`\`

## Manual Environment

- [ ] Tester name:
- [ ] Hardware model:
- [ ] Apple Silicon chip:
- [ ] macOS version:
- [ ] Test account type: clean user / second Mac / upgraded existing user
- [ ] Install path tested: DMG drag-to-Applications / direct app / package / MDM
- [ ] Signing channel tested: ad-hoc / local dev certificate / Developer ID notarized

## Install And First Launch

- [ ] Fresh install opens from Finder or Applications.
- [ ] If notarized, first launch opens without the right-click Gatekeeper bypass.
- [ ] If not notarized, right-click -> Open works and the warning text is understood.
- [ ] Menu-bar icon appears without a Dock window.
- [ ] Popover opens from the menu-bar icon.
- [ ] First launch creates \`~/Library/Application Support/YappYapp/config.json\`.
- [ ] First launch creates \`~/Library/Application Support/YappYapp/glossary.json\`.
- [ ] First launch creates \`~/Library/Application Support/YappYapp/models/\`.
- [ ] Previous support-folder migration or merge works when tested.

## Permissions

- [ ] Microphone permission prompt appears when expected.
- [ ] Recording works after microphone permission is granted.
- [ ] Missing Accessibility permission degrades to copy-only/manual paste.
- [ ] Accessibility permission request opens the correct System Settings pane.
- [ ] Auto-paste works after granting Accessibility permission.
- [ ] Rebuilding with the same stable signing identity preserves Accessibility permission.

## Dictation Controls

- [ ] \`option-space\` starts recording.
- [ ] \`option-space\` stops recording.
- [ ] \`esc\` cancels recording.
- [ ] Menu-bar context menu can start/stop dictation.
- [ ] Recording indicator appears in the configured position.
- [ ] Temporary WAV files are removed after transcription/cancel/error.
- [ ] \`./scripts/route_change_test.sh --list-devices\` lists available input devices.
- [ ] \`./scripts/route_change_test.sh --run\` passes, or skips because this Mac has fewer than two input devices.

## Paste Targets

- [ ] Native text field receives automatic insertion.
- [ ] Browser field receives paste fallback.
- [ ] Electron app field receives paste fallback.
- [ ] Terminal receives Cmd+V paste behavior rather than direct AX value writes.
- [ ] Password or secure input field is not written into.
- [ ] Clipboard restore behaves according to the setting.

### Target-App Paste Matrix

| Target class | App tested | Accessibility state | Expected path | Result / notes |
| --- | --- | --- | --- | --- |
| Native text field | TextEdit / Notes / Mail | granted | direct insertion |  |
| Browser editor | Safari / Chrome / Brave | granted | Cmd+V paste fallback |  |
| Electron/WebView editor | Slack / WhatsApp / Notion / VS Code / Cursor | granted | Cmd+V paste fallback |  |
| Terminal | Terminal / iTerm2 / Warp | granted | Cmd+V paste fallback |  |
| Secure input | password field / secure note | granted | no write; copy-only or blocked |  |
| No Accessibility permission | any text field | denied | clipboard-only fallback |  |

## Models And Offline Behavior

- [ ] Bundled \`whisper-cli\` and \`whisper-server\` are used from the app package when present.
- [ ] Whisper recommended model can be downloaded, verified, selected, and used.
- [ ] Existing local Whisper models are discovered in the YappYapp support folder.
- [ ] Parakeet model can be selected, first-use downloaded, and reused while warm.
- [ ] With \`allowModelDownloads: false\`, in-app Whisper downloads are blocked.
- [ ] With \`allowModelDownloads: false\`, Parakeet first-use network downloads are blocked or clearly fail offline.
- [ ] The shipped app package contains runtime helpers only, not model weights.

## App Settings

- [ ] Language auto-detect works for the tested language.
- [ ] Fixed language mode improves the expected language.
- [ ] TRANSLATE TO: a French dictation goes out in English (Hy-MT2), and with no model it goes out untranslated with a note.
- [ ] Filler-word removal toggle works.
- [ ] Quiet voice boost can be toggled and remains saved.
- [ ] Keep-model-warm toggle starts/stops warm Whisper behavior.
- [ ] Launch-at-login toggle can be enabled and disabled.
- [ ] Glossary corrections apply after transcription.
- [ ] Settings export works and import dry-run previews the expected files.
- [ ] App-data reset dry-run lists only the intended local files.

## Privacy Checks

- [ ] No cloud transcription API key is required.
- [ ] No transcript history is written to disk.
- [ ] Temporary audio is deleted after transcription.
- [ ] Clipboard manager caveat is documented for sensitive environments.
- [ ] Network use is limited to setup/model downloads unless models are preinstalled.

## Evidence To Attach To Release

- [ ] Completed report saved with release artifacts.
- [ ] Screenshot of menu-bar popover on clean account.
- [ ] Screenshot of Accessibility permission entry after grant.
- [ ] Screenshot or note for first model download/selection.
- [ ] Output of \`./scripts/verify_release.sh\`.
- [ ] Output of \`./scripts/check_hf_model_metadata.sh\`.
- [ ] Output of \`./scripts/check_ignore_policy.sh\`.
- [ ] Output of \`./scripts/check_no_model_weights.sh\`.
- [ ] Output of \`./scripts/check_privacy_artifacts.sh\`.
- [ ] Output of \`./scripts/check_network_policy.sh\`.
- [ ] Final \`dist/checksums.txt\`.

## Notes

EOF

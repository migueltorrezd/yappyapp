#!/usr/bin/env bash
set -euo pipefail

# YA-09: the publish runbook as a script. By default it only PRINTS every step
# with the exact commands, so you can read the whole release before anything
# leaves this Mac. Nothing is uploaded, pushed or committed unless you pass
# --execute, and even then each step asks for a "y" before it runs.
#
# Usage:
#   ./scripts/publish_release.sh                     print the plan
#   ./scripts/publish_release.sh --execute           run it, confirming each step
#   ./scripts/publish_release.sh --execute --from 4  resume at step 4
#
# Before step 1: run ./scripts/verify_release.sh with an explicit SIGN_IDENTITY
# so dist/YappYapp.dmg is the final signed (and, once available, notarized)
# DMG. See docs/RELEASE_CHECKLIST.md, "Publishing a release".
#
# Overrides: YAPPYAPP_RELEASES_REPO (default migueltorrezd/yappyapp-releases),
# YAPPYAPP_TAP_REPO (default migueltorrezd/homebrew-tap).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROVENANCE="$ROOT_DIR/docs/RELEASE_PROVENANCE.json"
RELEASES_REPO="${YAPPYAPP_RELEASES_REPO:-migueltorrezd/yappyapp-releases}"
TAP_REPO="${YAPPYAPP_TAP_REPO:-migueltorrezd/homebrew-tap}"
FEED_URL="https://raw.githubusercontent.com/$RELEASES_REPO/main/appcast.xml"

EXECUTE=0
FROM_STEP=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --execute) EXECUTE=1 ;;
    --from)
      FROM_STEP="${2:?--from needs a step number}"
      shift
      ;;
    -h | --help)
      sed -n '4,20p' "$0"
      exit 0
      ;;
    *)
      echo "error: unknown argument $1" >&2
      exit 2
      ;;
  esac
  shift
done
[[ "$FROM_STEP" =~ ^[0-9]+$ ]] || {
  echo "error: --from needs a step number" >&2
  exit 2
}

VERSION="$(plutil -extract app.short_version raw -o - "$PROVENANCE")"
BUILD="$(plutil -extract app.bundle_version raw -o - "$PROVENANCE")"
TAG="v$VERSION"
# Relative to the project root, where every step runs.
STAGE_DIR="dist/release-$VERSION"
WORK_DIR="$STAGE_DIR/work"
NOTES="$STAGE_DIR/release-notes.md"
VERSIONED_DMG="$STAGE_DIR/YappYapp-$VERSION.dmg"
EVERGREEN_DMG="$STAGE_DIR/YappYapp.dmg"
STAGED_CASK="$STAGE_DIR/yappyapp.rb"

STEP_NUMBER=0

# Prints a step, and in --execute mode runs it after a confirmation.
# $1 title, $2 why it matters, $3 the shell commands (run with bash -c).
step() {
  local title="$1" why="$2" commands="$3"
  STEP_NUMBER=$((STEP_NUMBER + 1))
  echo
  echo "== Step $STEP_NUMBER: $title"
  echo "   $why"
  local line
  while IFS= read -r line; do
    printf "     %s\n" "$line"
  done <<<"$commands"
  if [[ $EXECUTE -eq 0 || $STEP_NUMBER -lt $FROM_STEP ]]; then
    return 0
  fi
  local answer=""
  printf "   Run step %s now? [y/N/q] " "$STEP_NUMBER"
  read -r answer </dev/tty || answer=""
  case "$answer" in
    y | Y)
      (cd "$ROOT_DIR" && bash -euo pipefail -c "$commands") || {
        echo "   Step $STEP_NUMBER failed. Fix it, then resume with --execute --from $STEP_NUMBER." >&2
        exit 1
      }
      ;;
    q | Q)
      echo "   Stopped before step $STEP_NUMBER. Resume with --execute --from $STEP_NUMBER."
      exit 0
      ;;
    *) echo "   Skipped step $STEP_NUMBER." ;;
  esac
}

if [[ $EXECUTE -eq 1 ]]; then
  echo "Publishing YappYapp $VERSION (build $BUILD). Each step asks before it runs."
else
  echo "Publish plan for YappYapp $VERSION (build $BUILD). Nothing runs without --execute."
fi

step "Preflight" \
  "Clean tree, a new version, the final DMG in dist/, and gh signed in." \
  "test -z \"\$(git status --porcelain)\" || { echo 'commit or stash first' >&2; exit 1; }
gh auth status
./scripts/check_version_bump.sh
test -s dist/YappYapp.dmg
./scripts/release_artifacts_smoke.sh"

step "Stage the upload set" \
  "One DMG, two names, checksums and cask computed from the staged file (never typed by hand)." \
  "./scripts/stage_release_assets.sh
cat '$STAGE_DIR/checksum-line.md'"

step "Write the release notes" \
  "Start from the template in docs/RELEASE_CHECKLIST.md. The checksum line must be pasted unchanged." \
  "test -f '$NOTES' || { sed -n '/^## YappYapp <version>/,/^\`\`\`$/p' docs/RELEASE_CHECKLIST.md | sed '\$d' | sed 's/<version>/$VERSION/' > '$NOTES'; cat '$STAGE_DIR/checksum-line.md' >> '$NOTES'; }
\${EDITOR:-vi} '$NOTES'
grep -qF \"\$(cat '$STAGE_DIR/checksum-line.md')\" '$NOTES' || { echo 'release notes lack the staged checksum line' >&2; exit 1; }"

step "Create the GitHub release with both DMGs" \
  "Versioned DMG for Sparkle and the cask, evergreen YappYapp.dmg for the website link." \
  "./scripts/stage_release_assets.sh --check '$STAGE_DIR'
gh release create '$TAG' --repo '$RELEASES_REPO' --title 'YappYapp $VERSION' --notes-file '$NOTES' '$VERSIONED_DMG' '$EVERGREEN_DMG'"

step "Check the uploaded assets" \
  "GitHub's digest of each uploaded file must equal the staged SHA-256." \
  "sha=\$(shasum -a 256 '$VERSIONED_DMG' | awk '{print \$1}')
gh release view '$TAG' --repo '$RELEASES_REPO' --json assets --jq '.assets[] | .name + \" \" + .digest' | tee /dev/stderr \\
  | awk -v want=\"sha256:\$sha\" '\$2 != want { bad = 1 } END { exit bad }'"

step "Generate and commit the appcast" \
  "Signs the new DMG with the Sparkle EdDSA key (login keychain) and keeps every earlier item." \
  "rm -rf '$WORK_DIR' && mkdir -p '$WORK_DIR/appcast'
gh repo clone '$RELEASES_REPO' '$WORK_DIR/yappyapp-releases'
cp '$WORK_DIR/yappyapp-releases/appcast.xml' '$WORK_DIR/appcast-before.xml'
cp '$WORK_DIR/yappyapp-releases/appcast.xml' '$WORK_DIR/appcast/appcast.xml'
cp '$VERSIONED_DMG' '$WORK_DIR/appcast/'
./scripts/generate_appcast.sh '$WORK_DIR/appcast'
grep -q '<sparkle:version>$BUILD</sparkle:version>' '$WORK_DIR/appcast/appcast.xml'
for old in \$(sed -n 's:.*<sparkle\\:version>\\([0-9]*\\)</sparkle\\:version>.*:\\1:p' '$WORK_DIR/appcast-before.xml'); do
  grep -q \"<sparkle:version>\$old</sparkle:version>\" '$WORK_DIR/appcast/appcast.xml' || { echo \"appcast dropped build \$old\" >&2; exit 1; }
done
cp '$WORK_DIR/appcast/appcast.xml' '$WORK_DIR/yappyapp-releases/appcast.xml'
git -C '$WORK_DIR/yappyapp-releases' diff --stat
git -C '$WORK_DIR/yappyapp-releases' commit -am 'Appcast: YappYapp $VERSION (build $BUILD)'
git -C '$WORK_DIR/yappyapp-releases' push"

step "Bump the Homebrew cask" \
  "Copies the staged cask (version and sha256 from the final DMG) into the tap." \
  "gh repo clone '$TAP_REPO' '$WORK_DIR/homebrew-tap'
cp '$STAGED_CASK' '$WORK_DIR/homebrew-tap/Casks/yappyapp.rb'
ruby -c '$WORK_DIR/homebrew-tap/Casks/yappyapp.rb'
git -C '$WORK_DIR/homebrew-tap' diff --stat
git -C '$WORK_DIR/homebrew-tap' commit -am 'yappyapp $VERSION'
git -C '$WORK_DIR/homebrew-tap' push"

step "Sync the matd97 bridge" \
  "0.3.x installs still poll the matd97 feed; the bridge copy must match what was just published." \
  "./scripts/sync_matd97_bridge.sh '$WORK_DIR/appcast/appcast.xml' '$STAGED_CASK'
git add matd97-bridge
git commit -m 'matd97 bridge: YappYapp $VERSION'"

step "Check the live feed and downloads" \
  "Raw GitHub caches for about five minutes; rerun this step if the new build is not visible yet." \
  "curl -fsSL '$FEED_URL' | grep -q '<sparkle:version>$BUILD</sparkle:version>'
curl -fsSL 'https://raw.githubusercontent.com/matd97/yappyapp-releases/main/appcast.xml' | grep -q '<sparkle:version>$BUILD</sparkle:version>'
curl -fsSIL 'https://github.com/$RELEASES_REPO/releases/download/$TAG/YappYapp-$VERSION.dmg' | grep -q ' 200'
curl -fsSIL 'https://github.com/$RELEASES_REPO/releases/latest/download/YappYapp.dmg' | grep -q ' 200'
echo 'Live feed and downloads serve $VERSION (build $BUILD).'"

step "Confirm the key backups" \
  "Losing the Sparkle key means no more updates; losing the signing identity means every user re-grants Accessibility." \
  "echo 'Confirm both are in the password manager (docs/RELEASE_CHECKLIST.md, Key backup):'
echo '  - Sparkle EdDSA private key (generate_keys -x export)'
echo '  - YappYapp Dev signing identity (.p12 export with its password)'"

echo
if [[ $EXECUTE -eq 0 ]]; then
  echo "Plan printed. Run with --execute to publish, one confirmed step at a time."
else
  echo "Release $VERSION finished the steps you confirmed."
fi

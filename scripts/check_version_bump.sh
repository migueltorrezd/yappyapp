#!/usr/bin/env bash
set -euo pipefail

# YA-08: refuse to ship a build that reuses a published version. Sparkle
# compares CFBundleVersion, so a re-upload at the same build number is never
# offered to anyone, and bug reports cannot be tied to one binary.
#
# Reads the packaged Info.plist when dist/YappYapp.app exists, otherwise
# docs/RELEASE_PROVENANCE.json, then compares against the latest published
# release on GitHub (read-only `gh` calls). Skips with a note when `gh` is
# missing, signed out or offline.
#
# Overrides (tests and offline use):
#   YAPPYAPP_SKIP_PUBLISHED_VERSION_CHECK=1  skip entirely.
#   YAPPYAPP_PUBLISHED_TAG=v0.3.1            use this tag instead of asking gh.
#   YAPPYAPP_PUBLISHED_BUILD=4               use this appcast build instead of gh.
#   YAPPYAPP_RELEASES_REPO=owner/name        default migueltorrezd/yappyapp-releases.
#   YAPPYAPP_VERSION_INFO_PLIST=path         read this Info.plist.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROVENANCE="$ROOT_DIR/docs/RELEASE_PROVENANCE.json"
INFO_PLIST="${YAPPYAPP_VERSION_INFO_PLIST:-$ROOT_DIR/dist/YappYapp.app/Contents/Info.plist}"
RELEASES_REPO="${YAPPYAPP_RELEASES_REPO:-migueltorrezd/yappyapp-releases}"

if [[ "${YAPPYAPP_SKIP_PUBLISHED_VERSION_CHECK:-0}" == "1" ]]; then
  echo "SKIP published version check (YAPPYAPP_SKIP_PUBLISHED_VERSION_CHECK=1)"
  exit 0
fi

# Returns 0 when dotted version $1 is strictly greater than $2.
version_gt() {
  local IFS=.
  # Word splitting on dots is the point here.
  # shellcheck disable=SC2206
  local a=($1) b=($2)
  local i x y
  for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
    x="${a[i]:-0}"
    y="${b[i]:-0}"
    [[ "$x" =~ ^[0-9]+$ && "$y" =~ ^[0-9]+$ ]] || return 1
    if ((10#$x > 10#$y)); then
      return 0
    elif ((10#$x < 10#$y)); then
      return 1
    fi
  done
  return 1
}

if [[ -f "$INFO_PLIST" ]]; then
  source_label="packaged app"
  short_version="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")"
  bundle_version="$(plutil -extract CFBundleVersion raw -o - "$INFO_PLIST")"
else
  source_label="release provenance"
  short_version="$(plutil -extract app.short_version raw -o - "$PROVENANCE")"
  bundle_version="$(plutil -extract app.bundle_version raw -o - "$PROVENANCE")"
fi

published_tag="${YAPPYAPP_PUBLISHED_TAG:-}"
if [[ -z "$published_tag" ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "SKIP published version check: gh is not installed"
    exit 0
  fi
  if ! published_tag="$(gh release view --repo "$RELEASES_REPO" --json tagName --jq .tagName 2>/dev/null)" \
    || [[ -z "$published_tag" ]]; then
    echo "SKIP published version check: could not read the latest release of $RELEASES_REPO (gh signed out or offline)"
    exit 0
  fi
fi
published_version="${published_tag#v}"

published_build="${YAPPYAPP_PUBLISHED_BUILD:-}"
if [[ -z "$published_build" && -z "${YAPPYAPP_PUBLISHED_TAG:-}" ]]; then
  appcast="$(gh api "repos/$RELEASES_REPO/contents/appcast.xml" -H "Accept: application/vnd.github.raw" 2>/dev/null || true)"
  published_build="$(
    printf "%s\n" "$appcast" \
      | sed -n 's:.*<sparkle\:version>\([0-9][0-9]*\)</sparkle\:version>.*:\1:p' \
      | sort -n | tail -n 1
  )"
fi

failures=0
if [[ "$short_version" == "$published_version" ]]; then
  echo "FAIL $source_label version $short_version equals the latest published tag $published_tag; bump app.short_version and app.bundle_version in docs/RELEASE_PROVENANCE.json" >&2
  failures=$((failures + 1))
elif ! version_gt "$short_version" "$published_version"; then
  echo "FAIL $source_label version $short_version is not newer than the latest published tag $published_tag" >&2
  failures=$((failures + 1))
else
  echo "OK   $source_label version $short_version is newer than published $published_tag"
fi

if [[ -n "$published_build" ]]; then
  if [[ "$bundle_version" =~ ^[0-9]+$ ]] && ((10#$bundle_version > 10#$published_build)); then
    echo "OK   $source_label build $bundle_version is newer than the published appcast build $published_build"
  else
    echo "FAIL $source_label build $bundle_version is not newer than the published appcast build $published_build; Sparkle would never offer it" >&2
    failures=$((failures + 1))
  fi
else
  echo "SKIP published build comparison: appcast build number unavailable"
fi

if ((failures > 0)); then
  exit 1
fi

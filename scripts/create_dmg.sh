#!/usr/bin/env bash
set -euo pipefail

# Builds a distributable DMG with the drag-to-Applications layout.
# Run scripts/package_app.sh first.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/YappYapp.app"
DMG_PATH="$ROOT_DIR/dist/YappYapp.dmg"

if [[ ! -d "$APP_DIR" ]]; then
  echo "error: $APP_DIR not found. Run scripts/package_app.sh first." >&2
  exit 1
fi

# GATEKEEPER-DOC-M2: the first-open note points to the canonical Gatekeeper doc.
# The DMG must not depend on a URL being reachable, so we ALWAYS bundle
# docs/GATEKEEPER.md into the DMG and reference it by filename, so the note never
# depends on a URL. REPO_URL is optional: when it is set to a real repository URL
# we additionally surface the online link; when it is unset (the normal case) or
# still the "<owner>" template placeholder we ship no URL at all rather than a
# dead link, and never hard-fail on an unset REPO_URL.
REPO_URL="${REPO_URL:-}"
GATEKEEPER_DOC_URL=""
if [[ -n "$REPO_URL" && "$REPO_URL" != *"<owner>"* ]]; then
  GATEKEEPER_DOC_URL="${REPO_URL%/}/blob/main/docs/GATEKEEPER.md"
elif [[ "$REPO_URL" == *"<owner>"* ]]; then
  echo "note: ignoring placeholder REPO_URL ('$REPO_URL'); shipping bundled GATEKEEPER.md only." >&2
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# GATEKEEPER-DOC-M2: bundle the canonical Gatekeeper guide so the first-open note
# can always reference real, offline guidance shipped alongside the app.
cp "$ROOT_DIR/docs/GATEKEEPER.md" "$STAGING/GATEKEEPER.md"

# GATEKEEPER-DOC-M2: ship a visible first-open note inside the DMG. A
# notarized app (Developer ID signature plus a stapled ticket) opens with a
# plain double-click, so it gets the short note; every other build keeps the
# one-time Open Anyway steps.
app_signature="$(codesign -dv --verbose=4 "$APP_DIR" 2>&1 || true)"
if grep -q "^Authority=Developer ID Application" <<<"$app_signature" \
  && xcrun stapler validate "$APP_DIR" >/dev/null 2>&1; then
  cat > "$STAGING/FIRST-OPEN.txt" <<TXT
This YappYapp build is signed with a Developer ID and notarized by Apple.
Drag YappYapp to Applications and double-click it. macOS asks once whether
to open an app downloaded from the internet: click Open. Dictation audio and
transcripts stay on your Mac.

Full guide: see GATEKEEPER.md in this disk image.
TXT
else
cat > "$STAGING/FIRST-OPEN.txt" <<TXT
YappYapp is distributed outside the Mac App Store and is not yet notarized by
Apple, so macOS warns you the first time. Dictation audio and transcripts stay
on your Mac.

macOS 15 Sequoia / macOS 26 Tahoe: double-click YappYapp, click Done, then open
System Settings > Privacy & Security, scroll to the YappYapp message, click
Open Anyway, authenticate, and click Open.

macOS 14 Sonoma: right-click YappYapp > Open > Open.

Full guide: see GATEKEEPER.md in this disk image.
TXT
fi

# GATEKEEPER-DOC-M2: only append an online link when a real repository URL exists.
if [[ -n "$GATEKEEPER_DOC_URL" ]]; then
  cat >> "$STAGING/FIRST-OPEN.txt" <<TXT
Online version: ${GATEKEEPER_DOC_URL}
TXT
fi

rm -f "$DMG_PATH"

# INSTALLER-LAYOUT: prefer dmgbuild (pip install dmgbuild) for the real
# installer window: brutal background with a drag arrow, positioned icons,
# volume icon. Falls back to a plain hdiutil image when dmgbuild is missing
# so the script still works on a bare machine.
DMGBUILD="${DMGBUILD:-}"
if [[ ! -x "$DMGBUILD" ]] && command -v dmgbuild >/dev/null 2>&1; then
  DMGBUILD="$(command -v dmgbuild)"
fi

if [[ -x "$DMGBUILD" ]]; then
  "$DMGBUILD" \
    -s "$ROOT_DIR/scripts/dmg_settings.py" \
    -D "app=$STAGING/YappYapp.app" \
    -D "staging=$STAGING" \
    -D "background=$ROOT_DIR/Resources/dmg-background.tiff" \
    -D "icon=$ROOT_DIR/Resources/AppIcon.icns" \
    "YappYapp" "$DMG_PATH"
else
  echo "note: dmgbuild not found; building a plain DMG without installer layout." >&2
  hdiutil create \
    -volname "YappYapp" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH"
fi

# A Developer ID app ships in a Developer ID signed DMG: Gatekeeper's
# `spctl -t open --context context:primary-signature` and notarization of the
# disk image both expect the image itself to carry the signature. The identity
# is the one that signed the app (or DMG_SIGN_IDENTITY / SIGN_IDENTITY).
dmg_identity="${DMG_SIGN_IDENTITY:-${SIGN_IDENTITY:-}}"
if [[ -z "$dmg_identity" ]]; then
  dmg_identity="$(sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' <<<"${app_signature:-}" | head -n 1)"
fi
if [[ "$dmg_identity" == "Developer ID Application"* ]]; then
  codesign --force --timestamp --sign "$dmg_identity" "$DMG_PATH"
  codesign --verify --strict "$DMG_PATH"
  echo "Signed $DMG_PATH with '$dmg_identity'"
fi

echo "Created $DMG_PATH"
# GATEKEEPER-DOC-M2: keep this hint aligned with docs/GATEKEEPER.md and FIRST-OPEN.txt.
echo "Recipients of a build that is not notarized: see FIRST-OPEN.txt in the DMG (macOS 15+ uses System Settings -> Open Anyway; macOS 14 uses right-click -> Open)."

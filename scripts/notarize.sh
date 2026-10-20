#!/usr/bin/env bash
set -euo pipefail

# Notarizes the DMG so Gatekeeper opens it without warnings.
# REQUIRES a paid Apple Developer account and a "Developer ID Application"
# certificate in the keychain. Build with:
#   SIGN_IDENTITY="Developer ID Application: YOUR COMPANY (TEAMID)" ./scripts/package_app.sh
#
# One-time credential setup:
#   xcrun notarytool store-credentials yappyapp-notary \
#     --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"
#
# Then: ./scripts/notarize.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
DMG_PATH="$ROOT_DIR/dist/YappYapp.dmg"
APP_DIR="$ROOT_DIR/dist/YappYapp.app"
APP_ZIP="$ROOT_DIR/dist/YappYapp.app.zip"
PROFILE="${NOTARY_PROFILE:-yappyapp-notary}"

if [[ ! -d "$APP_DIR" ]]; then
  echo "error: $APP_DIR not found. Run scripts/package_app.sh first." >&2
  exit 1
fi

if ! codesign --verify --deep --strict "$APP_DIR" >/dev/null 2>&1; then
  echo "error: $APP_DIR code signature does not verify." >&2
  exit 1
fi

# YA-12: codesign prints Authority= lines only at --verbose=2 or higher.
# Capture first: `codesign ... | grep -q` under pipefail fails when grep exits
# early and codesign gets SIGPIPE, which rejected valid Developer ID builds.
signature_details="$(codesign -dv --verbose=4 "$APP_DIR" 2>&1 || true)"
if ! grep -q "^Authority=Developer ID Application" <<<"$signature_details"; then
  echo "error: $APP_DIR is not signed with a Developer ID Application certificate." >&2
  echo "       Rebuild with SIGN_IDENTITY=\"Developer ID Application: YOUR COMPANY (TEAMID)\" ./scripts/package_app.sh" >&2
  exit 1
fi

echo "Creating app zip for notarization..."
rm -f "$APP_ZIP"
(
  cd "$DIST_DIR"
  ditto -c -k --keepParent "YappYapp.app" "YappYapp.app.zip"
)

echo "Submitting app to Apple notary service (profile: $PROFILE)..."
xcrun notarytool submit "$APP_ZIP" --keychain-profile "$PROFILE" --wait

echo "Stapling app ticket..."
xcrun stapler staple "$APP_DIR"

echo "Recreating DMG with stapled app..."
"$ROOT_DIR/scripts/create_dmg.sh"

echo "Submitting DMG to Apple notary service (profile: $PROFILE)..."
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$PROFILE" --wait

echo "Stapling DMG ticket..."
xcrun stapler staple "$DMG_PATH"

echo "Rewriting dist/checksums.txt for the stapled DMG and app..."
"$ROOT_DIR/scripts/write_checksums.sh"

echo "Done. The DMG opens without Gatekeeper warnings on any Mac."

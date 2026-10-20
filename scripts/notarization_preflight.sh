#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/YappYapp.app"
DMG_PATH="$ROOT_DIR/dist/YappYapp.dmg"
PROFILE="${NOTARY_PROFILE:-yappyapp-notary}"
ONLINE_CHECK=0

failures=0
warnings=0

usage() {
  cat <<'EOF'
Usage: scripts/notarization_preflight.sh [--online]

Checks whether dist/YappYapp.app and dist/YappYapp.dmg are ready for the
Developer ID notarization path. The default mode is local-only and does not
submit anything to Apple. Use --online to also validate the configured
notarytool keychain profile with Apple's notary service.

Environment:
  NOTARY_PROFILE   Keychain profile name for notarytool. Default: yappyapp-notary
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --online)
      ONLINE_CHECK=1
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

cd "$ROOT_DIR" || exit

ok() {
  printf "OK   %s\n" "$1"
}

warn() {
  warnings=$((warnings + 1))
  printf "WARN %s\n" "$1"
}

fail() {
  failures=$((failures + 1))
  printf "FAIL %s\n" "$1"
}

capture() {
  "$@" 2>&1
}

printf "YappYapp notarization preflight\n"
printf "Root: %s\n" "$ROOT_DIR"
printf "Notary profile: %s\n\n" "$PROFILE"

if [[ -d "$APP_DIR" ]]; then
  ok "app bundle exists: $APP_DIR"
else
  fail "app bundle missing: $APP_DIR"
fi

if [[ -f "$DMG_PATH" ]]; then
  ok "DMG exists: $DMG_PATH"
else
  fail "DMG missing: $DMG_PATH"
fi

if xcrun --find notarytool >/dev/null 2>&1; then
  ok "notarytool found: $(xcrun --find notarytool)"
else
  fail "notarytool not found; install current Xcode Command Line Tools"
fi

if xcrun --find stapler >/dev/null 2>&1; then
  ok "stapler found: $(xcrun --find stapler)"
else
  fail "stapler not found; install current Xcode Command Line Tools"
fi

developer_ids="$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" || true)"
if [[ -n "$developer_ids" ]]; then
  ok "Developer ID Application signing identity found"
  printf "%s\n" "$developer_ids" | sed 's/^/     /'
else
  fail "no Developer ID Application signing identity found in the keychain"
fi

if [[ -d "$APP_DIR" ]]; then
  if codesign --verify --deep --strict --verbose=2 "$APP_DIR" >/dev/null 2>&1; then
    ok "app code signature verifies"
  else
    fail "app code signature does not verify"
  fi

  codesign_details="$(capture codesign -dv --verbose=4 "$APP_DIR" || true)"
  if printf "%s\n" "$codesign_details" | grep -q "Authority=Developer ID Application"; then
    ok "app is signed with Developer ID Application authority"
  else
    fail "app is not Developer ID signed; rebuild with SIGN_IDENTITY=\"Developer ID Application: ...\" ./scripts/package_app.sh"
  fi

  if printf "%s\n" "$codesign_details" | grep -Eq "flags=.*runtime|Runtime Version="; then
    ok "app signature includes hardened runtime"
  else
    fail "app signature does not show hardened runtime"
  fi

  if printf "%s\n" "$codesign_details" | grep -Eq "TeamIdentifier=[A-Z0-9]+"; then
    ok "app signature has a TeamIdentifier"
  else
    fail "app signature does not have a TeamIdentifier"
  fi

  app_spctl="$(capture spctl -a -vv -t exec "$APP_DIR" || true)"
  if printf "%s\n" "$app_spctl" | grep -q "accepted"; then
    ok "spctl accepts app"
  else
    warn "spctl does not accept app yet; this is expected before Developer ID signing/notarization"
    printf "%s\n" "$app_spctl" | sed 's/^/     /'
  fi

  app_stapler="$(capture xcrun stapler validate "$APP_DIR" || true)"
  if printf "%s\n" "$app_stapler" | grep -q "worked"; then
    ok "app has a stapled notarization ticket"
  else
    warn "app has no stapled notarization ticket yet"
    printf "%s\n" "$app_stapler" | sed 's/^/     /'
  fi
fi

if [[ -f "$DMG_PATH" ]]; then
  dmg_spctl="$(capture spctl -a -vv -t open --context context:primary-signature "$DMG_PATH" || true)"
  if printf "%s\n" "$dmg_spctl" | grep -q "accepted"; then
    ok "spctl accepts DMG"
  else
    warn "spctl does not accept DMG yet; this is expected before notarization/stapling"
    printf "%s\n" "$dmg_spctl" | sed 's/^/     /'
  fi

  dmg_stapler="$(capture xcrun stapler validate "$DMG_PATH" || true)"
  if printf "%s\n" "$dmg_stapler" | grep -q "worked"; then
    ok "DMG has a stapled notarization ticket"
  else
    warn "DMG has no stapled notarization ticket yet"
    printf "%s\n" "$dmg_stapler" | sed 's/^/     /'
  fi
fi

if (( ONLINE_CHECK == 1 )); then
  notary_history="/tmp/yappyapp-notary-preflight-history.$$"
  if xcrun notarytool history --keychain-profile "$PROFILE" --output-format json --no-progress >"$notary_history" 2>&1; then
    ok "notarytool profile '$PROFILE' authenticated with Apple"
    rm -f "$notary_history"
  else
    fail "notarytool profile '$PROFILE' could not authenticate with Apple"
    sed 's/^/     /' "$notary_history" 2>/dev/null || true
    rm -f "$notary_history"
  fi
else
  warn "notarytool profile authentication not checked; rerun with --online before release"
fi

printf "\nSummary: %d failure(s), %d warning(s)\n" "$failures" "$warnings"

if (( failures > 0 )); then
  exit 1
fi

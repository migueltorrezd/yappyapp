#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/YappYapp.app"

cd "$ROOT_DIR"
# YA-06: pick a macOS SDK whose SwiftUI macros this toolchain can expand.
# shellcheck source=scripts/lib/swift_sdk.sh
source "$ROOT_DIR/scripts/lib/swift_sdk.sh"
yappyapp_use_buildable_sdk || exit 1

echo "== Tests =="
./scripts/run_tests.sh

echo
echo "== Clean install smoke =="
./scripts/clean_install_smoke.sh

echo
echo "== Source install smoke =="
./scripts/source_install_smoke.sh

echo
echo "== Offline managed config smoke =="
./scripts/offline_config_smoke.sh

echo
echo "== Settings backup smoke =="
./scripts/settings_backup_smoke.sh

echo
echo "== Reset app data smoke =="
./scripts/reset_app_data_smoke.sh

echo
echo "== Route-change device inventory =="
./scripts/route_change_test.sh --list-devices

echo
echo "== Package =="
# FIX signing-identity: do not force ad-hoc ("-"). Let package_app.sh discover
# the stable "YappYapp Dev" identity so the TCC Accessibility grant survives
# rebuilds; only an explicitly exported SIGN_IDENTITY overrides that discovery.
./scripts/package_app.sh

echo
echo "== Release binary surface =="
./scripts/check_release_binary_surface.sh

echo
echo "== Packaged launch smoke =="
./scripts/launch_smoke.sh

echo
echo "== LaunchServices smoke =="
./scripts/launchservices_smoke.sh

echo
echo "== Packaged notices =="
./scripts/check_packaged_notices.sh

echo
echo "== Ignore policy =="
./scripts/check_ignore_policy.sh

echo
echo "== Documentation links =="
./scripts/check_docs_links.sh

echo
echo "== Model catalog sync =="
./scripts/check_model_catalog_sync.sh

echo
echo "== Model weight policy =="
./scripts/check_no_model_weights.sh

echo
echo "== Privacy artifact policy =="
./scripts/check_privacy_artifacts.sh

echo
echo "== Network policy =="
./scripts/check_network_policy.sh

echo
echo "== Release metadata =="
for required in LICENSE ROADMAP.md THIRD_PARTY_NOTICES.md docs/INSTALL.md docs/MODEL_DISTRIBUTION.md docs/RELEASE_CHECKLIST.md docs/RELEASE_PROVENANCE.json; do
  if [[ ! -s "$required" ]]; then
    echo "error: required release file missing or empty: $required" >&2
    exit 1
  fi
  echo "OK $required"
done

if ! grep -q "MIT License" LICENSE; then
  echo "error: LICENSE does not contain the expected MIT License heading" >&2
  exit 1
fi

bundle_id="$(plutil -extract CFBundleIdentifier raw "$APP_DIR/Contents/Info.plist")"
bundle_name="$(plutil -extract CFBundleName raw "$APP_DIR/Contents/Info.plist")"
if [[ "$bundle_id" != "app.yappyapp.YappYapp" ]]; then
  echo "error: unexpected bundle identifier: $bundle_id" >&2
  exit 1
fi
if [[ "$bundle_name" != "YappYapp" ]]; then
  echo "error: unexpected bundle name: $bundle_name" >&2
  exit 1
fi
echo "OK bundle identifier: $bundle_id"
echo "OK bundle name: $bundle_name"

echo
echo "== Release provenance =="
./scripts/check_provenance.sh

echo
echo "== Version bump against the published release =="
# YA-08: fails when this build reuses the latest published version or build
# number; skips when gh is unavailable.
./scripts/check_version_bump.sh

echo
echo "== Live model-card metadata =="
./scripts/check_hf_model_metadata.sh

echo
echo "== Code signature =="
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo
echo "== Doctor =="
./scripts/doctor.sh

echo
echo "== DMG =="
./scripts/create_dmg.sh

echo
echo "== DMG smoke =="
./scripts/dmg_smoke.sh

echo
echo "== Checksums =="
./scripts/write_checksums.sh

echo
echo "== Release artifacts smoke =="
./scripts/release_artifacts_smoke.sh

echo
echo "== Release tooling smoke =="
./scripts/release_tooling_smoke.sh

echo
echo "== Support report smoke =="
./scripts/support_report.sh >/dev/null

echo
echo "Release verification complete."

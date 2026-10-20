#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="YappYapp"
EXECUTABLE_NAME="YappYapp"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
NOTICES_DIR="$RESOURCES_DIR/Notices"
THIRD_PARTY_LICENSES_DIR="$NOTICES_DIR/ThirdParty"
BUNDLED_BIN_DIR="$ROOT_DIR/vendor/whisper.cpp/build/bin"
LLAMA_BIN_DIR="$ROOT_DIR/vendor/llama.cpp/build/bin"
ENTITLEMENTS="$ROOT_DIR/YappYapp.entitlements"

cd "$ROOT_DIR"
# YA-06: pick a macOS SDK whose SwiftUI macros this toolchain can expand.
# shellcheck source=scripts/lib/swift_sdk.sh
source "$ROOT_DIR/scripts/lib/swift_sdk.sh"
yappyapp_use_buildable_sdk || exit 1
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp ".build/release/$EXECUTABLE_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"

# Bundle the whisper runtime when the static build exists, so end users need
# neither Homebrew nor a terminal. Build it with scripts/bootstrap_whisper_cpp.sh
# or: cmake -B build -DBUILD_SHARED_LIBS=OFF -DGGML_METAL_EMBED_LIBRARY=ON
if [[ -x "$BUNDLED_BIN_DIR/whisper-cli" ]]; then
  mkdir -p "$RESOURCES_DIR/bin"
  cp "$BUNDLED_BIN_DIR/whisper-cli" "$RESOURCES_DIR/bin/whisper-cli"
  if [[ -x "$BUNDLED_BIN_DIR/whisper-server" ]]; then
    cp "$BUNDLED_BIN_DIR/whisper-server" "$RESOURCES_DIR/bin/whisper-server"
  fi
  echo "Bundled whisper runtime from $BUNDLED_BIN_DIR."
else
  echo "No bundled whisper runtime (vendor build missing); app will use Homebrew whisper-cpp."
fi

# LLM-CLEANUP (YA-10): bundle the pinned llama.cpp runtime so cleanup works
# out of the box. Build it with scripts/bootstrap_llama_cpp.sh. Without it the
# app says "Needs the cleanup runtime" and never downloads the model.
# llama-server, built from the same pinned source, keeps the model warm so
# cleanup skips the per-dictation load; llama-completion stays the fallback.
# QWEN3-ASR: llama-mtmd-cli is the one-shot audio helper for the Qwen3-ASR
# speech models; llama-server runs them warm.
if [[ -x "$LLAMA_BIN_DIR/llama-completion" ]]; then
  mkdir -p "$RESOURCES_DIR/bin"
  cp "$LLAMA_BIN_DIR/llama-completion" "$RESOURCES_DIR/bin/llama-completion"
  if [[ -x "$LLAMA_BIN_DIR/llama-server" ]]; then
    cp "$LLAMA_BIN_DIR/llama-server" "$RESOURCES_DIR/bin/llama-server"
  fi
  if [[ -x "$LLAMA_BIN_DIR/llama-mtmd-cli" ]]; then
    cp "$LLAMA_BIN_DIR/llama-mtmd-cli" "$RESOURCES_DIR/bin/llama-mtmd-cli"
  fi
  echo "Bundled llama.cpp cleanup runtime from $LLAMA_BIN_DIR."
else
  echo "No bundled llama.cpp runtime (vendor build missing); LLM cleanup will need a Homebrew llama-cli."
fi

# HELPER-BINARY-POLICY (YA-63): no build-machine rpaths in shipped binaries.
"$ROOT_DIR/scripts/strip_toolchain_rpaths.sh" "$MACOS_DIR/$EXECUTABLE_NAME" "$RESOURCES_DIR"/bin/*

if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

# L10N (YA-42): the interface tables live in SwiftPM's resource bundle. The
# app's L10n helper finds it in Contents/Resources (never via Bundle.module,
# which only looks next to the executable). The per-language InfoPlist.strings
# localize the microphone prompt and tell macOS which languages the app has.
L10N_BUNDLE="$ROOT_DIR/.build/release/YappYapp_YappYapp.bundle"
if [[ ! -d "$L10N_BUNDLE" ]]; then
  echo "error: localization bundle not found at $L10N_BUNDLE" >&2
  exit 1
fi
cp -R "$L10N_BUNDLE" "$RESOURCES_DIR/YappYapp_YappYapp.bundle"
for lang in en fr es nl; do
  if [[ ! -f "$RESOURCES_DIR/YappYapp_YappYapp.bundle/Contents/Resources/$lang.lproj/Localizable.strings" ]]; then
    echo "error: localization bundle is missing $lang.lproj" >&2
    exit 1
  fi
  mkdir -p "$RESOURCES_DIR/$lang.lproj"
  cp "$ROOT_DIR/Resources/Localization/$lang.lproj/InfoPlist.strings" "$RESOURCES_DIR/$lang.lproj/InfoPlist.strings"
  plutil -lint "$RESOURCES_DIR/$lang.lproj/InfoPlist.strings" >/dev/null
done

copy_notice() {
  local source="$1"
  local destination="$2"

  if [[ ! -s "$ROOT_DIR/$source" ]]; then
    echo "error: required notice missing or empty: $source" >&2
    exit 1
  fi

  cp "$ROOT_DIR/$source" "$destination"
}

mkdir -p "$NOTICES_DIR" "$THIRD_PARTY_LICENSES_DIR"
cp "$ROOT_DIR/LICENSE" "$NOTICES_DIR/LICENSE.txt"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$NOTICES_DIR/THIRD_PARTY_NOTICES.md"
cp "$ROOT_DIR/docs/RELEASE_PROVENANCE.json" "$NOTICES_DIR/RELEASE_PROVENANCE.json"
copy_notice "vendor/whisper.cpp/LICENSE" "$THIRD_PARTY_LICENSES_DIR/whisper.cpp-LICENSE.txt"
if [[ -x "$RESOURCES_DIR/bin/llama-completion" || -x "$RESOURCES_DIR/bin/llama-server" || -x "$RESOURCES_DIR/bin/llama-mtmd-cli" ]]; then
  copy_notice "vendor/llama.cpp/LICENSE" "$THIRD_PARTY_LICENSES_DIR/llama.cpp-LICENSE.txt"
  # Licenses of code vendored inside llama.cpp (for example nlohmann/json).
  if [[ -d "$ROOT_DIR/vendor/llama.cpp/licenses" ]]; then
    for license_file in "$ROOT_DIR"/vendor/llama.cpp/licenses/*; do
      [[ -f "$license_file" ]] || continue
      copy_notice "vendor/llama.cpp/licenses/$(basename "$license_file")" \
        "$THIRD_PARTY_LICENSES_DIR/llama.cpp-$(basename "$license_file").txt"
    done
  fi
fi
# cpp-httplib and nlohmann/json are compiled into whisper-server and the
# llama.cpp helpers; their license texts live in packaging/notices/.
if [[ -x "$RESOURCES_DIR/bin/whisper-server" || -x "$RESOURCES_DIR/bin/llama-completion" || -x "$RESOURCES_DIR/bin/llama-server" || -x "$RESOURCES_DIR/bin/llama-mtmd-cli" ]]; then
  copy_notice "packaging/notices/cpp-httplib-LICENSE.txt" "$THIRD_PARTY_LICENSES_DIR/cpp-httplib-LICENSE.txt"
  copy_notice "packaging/notices/nlohmann-json-LICENSE.txt" "$THIRD_PARTY_LICENSES_DIR/nlohmann-json-LICENSE.txt"
fi
copy_notice ".build/checkouts/FluidAudio/LICENSE" "$THIRD_PARTY_LICENSES_DIR/FluidAudio-LICENSE.txt"
copy_notice ".build/checkouts/FluidAudio/ThirdPartyLicenses/fastcluster-LICENSE.md" "$THIRD_PARTY_LICENSES_DIR/FluidAudio-fastcluster-LICENSE.md"
copy_notice ".build/checkouts/FluidAudio/ThirdPartyLicenses/vbx-LICENSE.md" "$THIRD_PARTY_LICENSES_DIR/FluidAudio-vbx-LICENSE.md"
copy_notice ".build/checkouts/Sparkle/LICENSE" "$THIRD_PARTY_LICENSES_DIR/Sparkle-LICENSE.txt"
cat > "$NOTICES_DIR/README.txt" <<'EOF'
YappYapp is distributed with local transcription runtime helpers and model
download metadata. Keep these notices with redistributed app bundles and DMGs.

- LICENSE.txt: YappYapp project license.
- THIRD_PARTY_NOTICES.md: runtime, dependency, and model-source notices.
- RELEASE_PROVENANCE.json: pinned release metadata and artifact checksums.
- ThirdParty/: full local license texts for bundled runtime helpers and
  compiled Swift package dependencies.
EOF

# FIX version-source: docs/RELEASE_PROVENANCE.json is the single source of truth
# for the shipped version/build, so the Info.plist below can no longer drift from
# provenance (env overrides allowed for local experiments).
PROVENANCE="$ROOT_DIR/docs/RELEASE_PROVENANCE.json"
SHORT_VERSION="${YAPPYAPP_SHORT_VERSION:-$(plutil -extract app.short_version raw -o - "$PROVENANCE")}"
BUNDLE_VERSION="${YAPPYAPP_BUNDLE_VERSION:-$(plutil -extract app.bundle_version raw -o - "$PROVENANCE")}"
if [[ -z "$SHORT_VERSION" || -z "$BUNDLE_VERSION" ]]; then
  echo "error: could not read app.short_version/app.bundle_version from $PROVENANCE" >&2
  exit 1
fi

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>YappYapp</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>app.yappyapp.YappYapp</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>fr</string>
    <string>es</string>
    <string>nl</string>
  </array>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>YappYapp</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${SHORT_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUNDLE_VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>YappYapp records your voice locally so it can transcribe dictation on this Mac.</string>
  <key>SUFeedURL</key>
  <string>https://raw.githubusercontent.com/migueltorrezd/yappyapp-releases/main/appcast.xml</string>
  <key>SUPublicEDKey</key>
  <string>yhJ8dWNWs1l1KMcT4e+5Q4xbGag0szs+Hx6x1Bjz0CU=</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>86400</integer>
</dict>
</plist>
EOF

plutil -lint "$CONTENTS_DIR/Info.plist"

# UPDATES: embed Sparkle.framework (SPM binary artifact) so the packaged app
# can self-update. The dev binary links it via @rpath; without this copy the
# packaged app would crash at launch.
SPARKLE_FRAMEWORK="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  echo "error: Sparkle.framework not found at $SPARKLE_FRAMEWORK (run swift build first)" >&2
  exit 1
fi
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"
rm -rf "$FRAMEWORKS_DIR/Sparkle.framework"
cp -R "$SPARKLE_FRAMEWORK" "$FRAMEWORKS_DIR/Sparkle.framework"

# Sign nested helpers first, then the app, with hardened runtime throughout
# (required for notarization). The stable identity is mandatory when it
# exists: an ad-hoc fallback silently invalidates the TCC Accessibility
# grant and auto-paste degrades to copy-only with no obvious cause.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="-"
  candidate="YappYapp Dev"
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "$candidate"; then
    SIGN_IDENTITY="$candidate"
  fi
fi
CODESIGN_TIMEOUT_SECONDS="${CODESIGN_TIMEOUT_SECONDS:-300}"

# Developer ID builds: every signature carries a secure timestamp (notarization
# requires it), and library validation stays on. The app and Sparkle.framework
# share the Team ID, so the disable-library-validation entitlement that the
# self-signed "YappYapp Dev" identity needs is stripped from a temporary copy.
TIMESTAMP_ARGS=()
SIGN_ENTITLEMENTS="$ENTITLEMENTS"
if [[ "$SIGN_IDENTITY" == "Developer ID Application"* ]]; then
  TIMESTAMP_ARGS=(--timestamp)
  SIGN_ENTITLEMENTS="$(mktemp -t yappyapp-entitlements).plist"
  cp "$ENTITLEMENTS" "$SIGN_ENTITLEMENTS"
  # PlistBuddy, not plutil: plutil reads the dots in the key as a key path.
  /usr/libexec/PlistBuddy -c "Delete :com.apple.security.cs.disable-library-validation" "$SIGN_ENTITLEMENTS" >/dev/null 2>&1 || true
  if /usr/libexec/PlistBuddy -c "Print :com.apple.security.cs.disable-library-validation" "$SIGN_ENTITLEMENTS" >/dev/null 2>&1; then
    echo "error: could not drop disable-library-validation for the Developer ID build" >&2
    exit 1
  fi
  plutil -lint "$SIGN_ENTITLEMENTS" >/dev/null
fi

run_with_timeout() {
  local seconds="$1"
  shift
  local marker
  marker="$(mktemp)"
  rm -f "$marker"

  "$@" &
  local pid=$!

  (
    sleep "$seconds"
    if kill -0 "$pid" 2>/dev/null; then
      printf "timed out\n" > "$marker"
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
    fi
  ) &
  local watcher=$!

  local status=0
  wait "$pid" || status=$?
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true

  if [[ -f "$marker" ]]; then
    rm -f "$marker"
    echo "error: command timed out after ${seconds}s: $*" >&2
    return 124
  fi

  rm -f "$marker"
  return "$status"
}

sign_bundle() {
  local identity="$1"
  if [[ -d "$RESOURCES_DIR/bin" ]]; then
    for helper in "$RESOURCES_DIR"/bin/*; do
      run_with_timeout "$CODESIGN_TIMEOUT_SECONDS" codesign --force --options runtime ${TIMESTAMP_ARGS[@]+"${TIMESTAMP_ARGS[@]}"} --sign "$identity" "$helper"
    done
  fi
  # Sparkle ships nested executables (XPC services, Autoupdate, Updater.app)
  # that notarization requires to be signed individually, innermost first.
  local sparkle="$FRAMEWORKS_DIR/Sparkle.framework"
  if [[ -d "$sparkle" ]]; then
    for nested in \
      "$sparkle/Versions/B/XPCServices/Downloader.xpc" \
      "$sparkle/Versions/B/XPCServices/Installer.xpc" \
      "$sparkle/Versions/B/Autoupdate" \
      "$sparkle/Versions/B/Updater.app"; do
      if [[ -e "$nested" ]]; then
        # Sparkle's documented signing keeps the Downloader service's own
        # entitlements (it is only used by sandboxed hosts).
        preserve=()
        [[ "$nested" == *Downloader.xpc ]] && preserve=(--preserve-metadata=entitlements)
        run_with_timeout "$CODESIGN_TIMEOUT_SECONDS" codesign --force --options runtime ${TIMESTAMP_ARGS[@]+"${TIMESTAMP_ARGS[@]}"} ${preserve[@]+"${preserve[@]}"} --sign "$identity" "$nested"
      fi
    done
    run_with_timeout "$CODESIGN_TIMEOUT_SECONDS" codesign --force --options runtime ${TIMESTAMP_ARGS[@]+"${TIMESTAMP_ARGS[@]}"} --sign "$identity" "$sparkle"
  fi
  # L10N: the resource bundle carries SwiftPM's ad-hoc seal; re-seal it with
  # the app's identity so the nested signature matches.
  if [[ -d "$RESOURCES_DIR/YappYapp_YappYapp.bundle" ]]; then
    run_with_timeout "$CODESIGN_TIMEOUT_SECONDS" codesign --force ${TIMESTAMP_ARGS[@]+"${TIMESTAMP_ARGS[@]}"} --sign "$identity" "$RESOURCES_DIR/YappYapp_YappYapp.bundle"
  fi
  run_with_timeout "$CODESIGN_TIMEOUT_SECONDS" codesign --force --options runtime ${TIMESTAMP_ARGS[@]+"${TIMESTAMP_ARGS[@]}"} --entitlements "$SIGN_ENTITLEMENTS" --sign "$identity" "$APP_DIR"
}

if sign_bundle "$SIGN_IDENTITY"; then
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "Signed ad-hoc. Run scripts/create_signing_identity.sh for a stable identity."
  else
    echo "Signed with stable identity '$SIGN_IDENTITY' (Accessibility grant survives rebuilds)."
  fi
else
	  echo "error: signing with '$SIGN_IDENTITY' failed (keychain locked?)." >&2
	  echo "       Unlock the login keychain or fix permanently with:" >&2
	  echo "       security set-key-partition-list -S apple-tool:,apple: -s -l \"$SIGN_IDENTITY\" ~/Library/Keychains/login.keychain-db" >&2
  exit 1
fi

# Belt and braces: confirm the final signature actually carries the
# certificate, not a per-build cdhash requirement.
if [[ "$SIGN_IDENTITY" != "-" ]] && ! codesign -d -r- "$APP_DIR" 2>&1 | grep -q "certificate leaf"; then
  echo "error: $APP_DIR ended up ad-hoc signed; Accessibility will not recognize it." >&2
  exit 1
fi

echo "Created $APP_DIR"
echo "Run with: open '$APP_DIR'"

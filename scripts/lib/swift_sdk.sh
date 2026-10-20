# shellcheck shell=bash
# Picks a macOS SDK that can build YappYapp's SwiftUI views and exports it as
# SDKROOT. Source this file, then call `yappyapp_use_buildable_sdk || exit 1`.
#
# Why: newer SDKs declare SwiftUI's @State as an external macro implemented by
# the SwiftUIMacros compiler plugin. Xcode ships that plugin; Command Line
# Tools alone do not. With only Command Line Tools installed, the default SDK
# (for example macOS 27) then fails with "external macro implementation type
# 'SwiftUIMacros.StateMacro' could not be found". An older SDK that still
# declares @State as a plain property wrapper (for example macOS 26.5) builds
# fine, so we prefer the newest SDK that actually builds.
#
# Overrides:
#   SDKROOT                        an explicit SDK is respected as is.
#   YAPPYAPP_SDK_SEARCH_DIRS       colon-separated folders holding MacOSX*.sdk.
#   YAPPYAPP_DEFAULT_SDK           the SDK xcrun would pick (tests only).
#   YAPPYAPP_SWIFT_PLUGIN_DIRS     colon-separated compiler plugin folders.

yappyapp_sdk_default() {
  if [[ -n "${YAPPYAPP_DEFAULT_SDK+x}" ]]; then
    printf "%s\n" "$YAPPYAPP_DEFAULT_SDK"
    return
  fi
  xcrun --sdk macosx --show-sdk-path 2>/dev/null || true
}

yappyapp_developer_dir() {
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    printf "%s\n" "$DEVELOPER_DIR"
    return
  fi
  xcode-select -p 2>/dev/null || true
}

yappyapp_sdk_search_dirs() {
  if [[ -n "${YAPPYAPP_SDK_SEARCH_DIRS+x}" ]]; then
    tr ':' '\n' <<<"$YAPPYAPP_SDK_SEARCH_DIRS"
    return
  fi
  local developer_dir
  developer_dir="$(yappyapp_developer_dir)"
  if [[ -n "$developer_dir" ]]; then
    printf "%s\n" "$developer_dir/SDKs"
    printf "%s\n" "$developer_dir/Platforms/MacOSX.platform/Developer/SDKs"
  fi
  printf "%s\n" "/Library/Developer/CommandLineTools/SDKs"
}

yappyapp_swift_plugin_dirs() {
  if [[ -n "${YAPPYAPP_SWIFT_PLUGIN_DIRS+x}" ]]; then
    tr ':' '\n' <<<"$YAPPYAPP_SWIFT_PLUGIN_DIRS"
    return
  fi
  local swift_path toolchain_usr developer_dir
  swift_path="$(xcrun --find swift 2>/dev/null || true)"
  if [[ -n "$swift_path" ]]; then
    toolchain_usr="$(cd "$(dirname "$swift_path")/.." 2>/dev/null && pwd -P || true)"
    if [[ -n "$toolchain_usr" ]]; then
      printf "%s\n" "$toolchain_usr/lib/swift/host/plugins"
      printf "%s\n" "$toolchain_usr/local/lib/swift/host/plugins"
    fi
  fi
  developer_dir="$(yappyapp_developer_dir)"
  if [[ -n "$developer_dir" ]]; then
    printf "%s\n" "$developer_dir/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
    printf "%s\n" "$developer_dir/Platforms/MacOSX.platform/Developer/usr/local/lib/swift/host/plugins"
  fi
}

# True when the SDK's SwiftUI interfaces (SwiftUI or SwiftUICore) implement
# @State through the SwiftUIMacros plugin.
yappyapp_sdk_needs_swiftui_plugin() {
  local frameworks="$1/System/Library/Frameworks" interface
  for interface in \
    "$frameworks"/SwiftUI.framework/Modules/*.swiftmodule/*-apple-macos.swiftinterface \
    "$frameworks"/SwiftUICore.framework/Modules/*.swiftmodule/*-apple-macos.swiftinterface; do
    [[ -f "$interface" ]] || continue
    if grep -qs 'type: "StateMacro"' "$interface"; then
      return 0
    fi
  done
  return 1
}

yappyapp_swiftui_plugin_available() {
  local dir
  while IFS= read -r dir; do
    [[ -n "$dir" && -d "$dir" ]] || continue
    if compgen -G "$dir/*SwiftUIMacros*" >/dev/null; then
      return 0
    fi
  done < <(yappyapp_swift_plugin_dirs)
  return 1
}

yappyapp_sdk_is_buildable() {
  local sdk="$1"
  [[ -d "$sdk/System/Library/Frameworks/SwiftUI.framework" ]] || return 1
  if yappyapp_sdk_needs_swiftui_plugin "$sdk"; then
    yappyapp_swiftui_plugin_available
    return
  fi
  return 0
}

# Prints candidate SDK paths, best first: the toolchain default, then every
# versioned MacOSX<version>.sdk from newest to oldest, each real path once.
yappyapp_sdk_candidates() {
  local seen=$'\n' sdk real dir default_sdk
  default_sdk="$(yappyapp_sdk_default)"
  {
    if [[ -n "$default_sdk" ]]; then
      printf "999999.999999\t%s\n" "$default_sdk"
    fi
    while IFS= read -r dir; do
      [[ -n "$dir" && -d "$dir" ]] || continue
      for sdk in "$dir"/MacOSX*.sdk; do
        [[ -d "$sdk" ]] || continue
        local name version major minor
        name="$(basename "$sdk" .sdk)"
        version="${name#MacOSX}"
        [[ "$version" =~ ^[0-9]+(\.[0-9]+)?$ ]] || continue
        major="${version%%.*}"
        minor=0
        [[ "$version" == *.* ]] && minor="${version#*.}"
        printf "%d.%06d\t%s\n" "$major" "$minor" "$sdk"
      done
    done < <(yappyapp_sdk_search_dirs)
  } | sort -t$'\t' -k1,1 -n -r -s | while IFS=$'\t' read -r _ sdk; do
    real="$(cd "$sdk" 2>/dev/null && pwd -P || true)"
    [[ -n "$real" ]] || continue
    case "$seen" in
      *$'\n'"$real"$'\n'*) continue ;;
    esac
    seen+="$real"$'\n'
    printf "%s\n" "$sdk"
  done
}

# Prints the SDK YappYapp should build against, or fails with no output.
yappyapp_find_buildable_sdk() {
  local sdk
  while IFS= read -r sdk; do
    if yappyapp_sdk_is_buildable "$sdk"; then
      printf "%s\n" "$sdk"
      return 0
    fi
  done < <(yappyapp_sdk_candidates)
  return 1
}

yappyapp_sdk_help() {
  cat >&2 <<'EOF'
error: no installed macOS SDK can build YappYapp's SwiftUI views.
       The installed SDKs need the SwiftUIMacros compiler plugin, which ships
       with Xcode but not with the Command Line Tools alone.
       Fix one of these ways:
         1. Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app
         2. Install a Command Line Tools package that still includes the
            macOS 26 SDK (MacOSX26.x.sdk).
         3. Point SDKROOT at a working SDK: export SDKROOT=/path/to/MacOSX26.5.sdk
EOF
}

# Exports SDKROOT for this shell and every child (swift build, swift test).
yappyapp_use_buildable_sdk() {
  if [[ -n "${SDKROOT:-}" ]]; then
    if [[ ! -d "$SDKROOT" ]]; then
      echo "error: SDKROOT points to a missing SDK: $SDKROOT" >&2
      return 1
    fi
    export SDKROOT
    return 0
  fi
  local sdk
  if ! sdk="$(yappyapp_find_buildable_sdk)"; then
    yappyapp_sdk_help
    return 1
  fi
  export SDKROOT="$sdk"
  if [[ "$sdk" != "$(yappyapp_sdk_default)" ]]; then
    echo "note: building against $sdk (the default SDK needs Xcode's SwiftUI macro plugin)." >&2
  fi
}

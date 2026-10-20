#!/usr/bin/env bash
set -euo pipefail

# Runs the standalone pure-logic test target, the built-in integration suite
# (logic + UX state machine + offscreen UI renders), then the end-to-end
# dictation pipeline test.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# YA-06: pick a macOS SDK whose SwiftUI macros this toolchain can expand.
# shellcheck source=scripts/lib/swift_sdk.sh
source "$ROOT_DIR/scripts/lib/swift_sdk.sh"
yappyapp_use_buildable_sdk || exit 1

mkdir -p "$ROOT_DIR/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/module-cache}"

strict_swift_flags=(
  -Xswiftc -strict-concurrency=complete
  -Xswiftc -warnings-as-errors
)

swift build --disable-sandbox "${strict_swift_flags[@]}"
swift test --disable-sandbox "${strict_swift_flags[@]}"
.build/debug/YappYapp --self-test
./scripts/e2e_test.sh

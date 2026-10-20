#!/usr/bin/env bash
# HELPER-BINARY-POLICY (YA-63): drop LC_RPATH entries that point at build
# machine paths (Xcode or Command Line Tools toolchains, .build folders, home
# directories) from shipped Mach-O files. A leftover absolute rpath lets a
# library dropped at that path on a user's Mac load into a process that holds
# Microphone and Accessibility grants. Kept: @executable_path, @loader_path,
# and the OS Swift runtime in /usr/lib/swift.
#
# Usage: scripts/strip_toolchain_rpaths.sh <mach-o> [<mach-o> ...]
# Run before codesign: install_name_tool invalidates any signature.
set -euo pipefail

keep_rpath() {
  case "$1" in
    @executable_path*|@loader_path*|/usr/lib/swift|/usr/lib/swift/*) return 0 ;;
    *) return 1 ;;
  esac
}

for binary in "$@"; do
  [[ -f "$binary" ]] || continue
  if ! file -b "$binary" | grep -q "Mach-O"; then
    continue
  fi
  # Each LC_RPATH load command prints "path <value> (offset N)" two lines after it.
  rpaths=()
  while IFS= read -r rpath; do
    rpaths+=("$rpath")
  done < <(otool -l "$binary" | awk '/cmd LC_RPATH/ { getline; getline; sub(/^ *path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print }')

  for rpath in ${rpaths[@]+"${rpaths[@]}"}; do
    if keep_rpath "$rpath"; then
      continue
    fi
    install_name_tool -delete_rpath "$rpath" "$binary"
    echo "Stripped rpath $rpath from $(basename "$binary")."
  done
done

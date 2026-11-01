#!/bin/bash
# Quick input: token parsing, links, routing of Enter, queue, and real key events in the real panel.
# Pass --snapshot DIR to also capture the panel, light and dark (needs Screen Recording for the glass).
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
app_sources=()
for file in Sources/WhileAIWorks/*.swift; do
    [[ "$file" == */Main.swift ]] || app_sources+=("$file")
done
xcrun swiftc "${swift_flags[@]}" -Onone -parse-as-library -I "$build_dir" -L "$build_dir" -lWhileCore "${rive_flags[@]}" \
    "${app_sources[@]}" Tests/NativeQuickInputChecks.swift -o "$build_dir/NativeQuickInputChecks"
"$build_dir/NativeQuickInputChecks" "$@"

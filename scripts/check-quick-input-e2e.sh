#!/bin/bash
# Starts real agents in the default terminal and waits for their sessions to appear.
# Spends a little quota and leaves the sessions open. Not part of the regular checks.
# Usage: check-quick-input-e2e.sh <trusted directory> [codexCLI claudeCode hermes] [--resume] [--open]
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
app_sources=()
for file in Sources/WhileAIWorks/*.swift; do
    [[ "$file" == */Main.swift ]] || app_sources+=("$file")
done
xcrun swiftc "${swift_flags[@]}" -Onone -parse-as-library -I "$build_dir" -L "$build_dir" -lWhileCore "${rive_flags[@]}" \
    "${app_sources[@]}" Tests/NativeQuickInputEndToEnd.swift -o "$build_dir/NativeQuickInputEndToEnd"
"$build_dir/NativeQuickInputEndToEnd" "$@"

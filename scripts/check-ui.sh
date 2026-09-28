#!/bin/bash
# Offscreen renders of the menu bar panel, settings and collection, light and dark.
# Run design/mascot/stills.sh first to show the real cat instead of the symbol.
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
app_sources=()
for file in Sources/WhileAIWorks/*.swift; do
    [[ "$file" == */Main.swift ]] || app_sources+=("$file")
done
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library -I .build/native -L .build/native -lWhileCore "${rive_flags[@]}" \
 "${app_sources[@]}" Tests/NativeUIReviewChecks.swift -o .build/native/NativeUIReviewChecks
.build/native/NativeUIReviewChecks

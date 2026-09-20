#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
app_sources=()
for file in Sources/WhileAIWorks/*.swift; do
    [[ "$file" == */Main.swift ]] || app_sources+=("$file")
done
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library -I .build/native -L .build/native -lWhileCore \
 "${app_sources[@]}" Tests/NativeMysteryChecks.swift -o .build/native/NativeMysteryChecks
.build/native/NativeMysteryChecks

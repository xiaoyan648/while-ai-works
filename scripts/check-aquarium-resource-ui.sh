#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library -I "$build_dir" -L "$build_dir" -lWhileCore \
    Sources/WhileAIWorks/AquariumResources.swift Sources/WhileAIWorks/AquariumResourcePrompt.swift \
    Sources/WhileAIWorks/Theme.swift Tests/AquariumResourcePromptChecks.swift \
    -o "$build_dir/AquariumResourcePromptChecks"
"$build_dir/AquariumResourcePromptChecks"

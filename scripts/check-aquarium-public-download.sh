#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
output="$task_root/.build/aquarium-public-download"
mkdir -p "$output"
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library \
    Sources/WhileAIWorks/AquariumResources.swift Tests/AquariumPublicDownloadChecks.swift \
    -o "$output/AquariumPublicDownloadChecks"
"$output/AquariumPublicDownloadChecks" "${1:-Sources/WhileAIWorks/Resources/AquariumPack.json}"

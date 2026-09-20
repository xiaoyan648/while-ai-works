#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
mkdir -p docs/optimization-0.13.0
cp -R Sources/WhileAIWorks/Resources/FishAssets .build/native/
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library -I .build/native -L .build/native -lWhileCore \
 Sources/WhileAIWorks/AppState.swift Sources/WhileAIWorks/Audio.swift Sources/WhileAIWorks/PlaySurface.swift \
 Sources/WhileAIWorks/BubbleDrawing.swift Sources/WhileAIWorks/WoodfishDrawing.swift Sources/WhileAIWorks/InteractionDrawing.swift \
 Sources/WhileAIWorks/FishingDrawing.swift Tests/NativeRiverPresentationChecks.swift -o .build/native/NativeRiverPresentationChecks
.build/native/NativeRiverPresentationChecks

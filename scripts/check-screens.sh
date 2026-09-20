#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library -I .build/native -L .build/native -lWhileCore \
 Sources/WhileAIWorks/AppState.swift Sources/WhileAIWorks/Audio.swift Sources/WhileAIWorks/PlaySurface.swift \
 Sources/WhileAIWorks/BubbleDrawing.swift Sources/WhileAIWorks/WoodfishDrawing.swift Sources/WhileAIWorks/InteractionDrawing.swift \
 Sources/WhileAIWorks/FishingDrawing.swift Sources/WhileAIWorks/DesktopOverlay.swift Tests/NativeScreenChecks.swift -o .build/native/NativeScreenChecks
.build/native/NativeScreenChecks

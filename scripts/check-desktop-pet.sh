#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library -I .build/native -L .build/native -lWhileCore "${rive_flags[@]}" \
    Sources/WhileAIWorks/AppState.swift Sources/WhileAIWorks/Audio.swift Sources/WhileAIWorks/Theme.swift \
    Sources/WhileAIWorks/MascotView.swift Sources/WhileAIWorks/DesktopPet.swift Sources/WhileAIWorks/InteractionDrawing.swift Sources/WhileAIWorks/FishingSprites.swift \
    Tests/NativeDesktopPetChecks.swift -o .build/native/NativeDesktopPetChecks
.build/native/NativeDesktopPetChecks "$@"

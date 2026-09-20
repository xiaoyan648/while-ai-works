#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library -I .build/native -L .build/native -lWhileCore \
 Sources/WhileAIWorks/PackedMesh.swift Sources/WhileAIWorks/AquariumGlass.swift Sources/WhileAIWorks/AquariumNavigation.swift Sources/WhileAIWorks/GeneratedFish.swift Sources/WhileAIWorks/GeneratedPuffer.swift Sources/WhileAIWorks/GeneratedAquascape.swift Sources/WhileAIWorks/Aquarium3D.swift Tests/NativeAquariumFrameChecks.swift -o .build/native/NativeAquariumFrameChecks
.build/native/NativeAquariumFrameChecks

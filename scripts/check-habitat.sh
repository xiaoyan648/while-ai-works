#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
cp -R Sources/WhileAIWorks/Resources/AquariumAssets .build/native/
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library -I .build/native -L .build/native -lWhileCore \
 Sources/WhileAIWorks/PackedMesh.swift Sources/WhileAIWorks/AquariumGlass.swift Sources/WhileAIWorks/AquariumNavigation.swift Sources/WhileAIWorks/GeneratedFish.swift Sources/WhileAIWorks/GeneratedPuffer.swift Sources/WhileAIWorks/GeneratedAquascape.swift Sources/WhileAIWorks/Aquarium3D.swift Tests/NativeHabitatChecks.swift -o .build/native/NativeHabitatChecks
.build/native/NativeHabitatChecks

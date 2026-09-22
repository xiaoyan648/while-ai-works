#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
# Exercise the same optimization mode as the shipped animation/navigation code.
swift_flags+=(-O)
cp -R Sources/WhileAIWorks/Resources/FishAssets .build/native/
cp -R Sources/WhileAIWorks/Resources/AquariumAssets .build/native/
xcrun swiftc "${swift_flags[@]}" -parse-as-library -emit-module -emit-library -static \
    -module-name WhileCore Sources/WhileCore/*.swift \
    -emit-module-path .build/native/WhileCore.swiftmodule -o .build/native/libWhileCore.a
xcrun swiftc "${swift_flags[@]}" -parse-as-library -I .build/native -L .build/native \
    -lWhileCore Tests/WhileCoreTests/Checks.swift -o .build/native/CoreChecks
.build/native/CoreChecks
xcrun swiftc "${swift_flags[@]}" -parse-as-library -I .build/native -L .build/native \
    -lWhileCore Sources/WhileAIWorks/Audio.swift Tests/NativeAudioChecks.swift -o .build/native/NativeAudioChecks
.build/native/NativeAudioChecks
xcrun swiftc "${swift_flags[@]}" -parse-as-library -I .build/native -L .build/native -lWhileCore \
    Sources/WhileAIWorks/AppState.swift Sources/WhileAIWorks/Audio.swift Sources/WhileAIWorks/PlaySurface.swift \
    Sources/WhileAIWorks/BubbleDrawing.swift Sources/WhileAIWorks/WoodfishDrawing.swift Sources/WhileAIWorks/InteractionDrawing.swift \
    Sources/WhileAIWorks/FishingDrawing.swift Sources/WhileAIWorks/InteractionShortcut.swift Tests/NativeInteractionChecks.swift -o .build/native/NativeInteractionChecks
.build/native/NativeInteractionChecks
xcrun swiftc "${swift_flags[@]}" -parse-as-library Sources/WhileAIWorks/InteractionDrawing.swift \
    Tests/NativeArtworkChecks.swift -o .build/native/NativeArtworkChecks
.build/native/NativeArtworkChecks
xcrun swiftc "${swift_flags[@]}" -parse-as-library -I .build/native -L .build/native -lWhileCore \
    Tests/FishingChecks.swift -o .build/native/FishingChecks
.build/native/FishingChecks
xcrun swiftc "${swift_flags[@]}" -parse-as-library -I .build/native -L .build/native -lWhileCore \
    Sources/WhileAIWorks/AquariumGlass.swift Sources/WhileAIWorks/AquariumNavigation.swift Sources/WhileAIWorks/PackedMesh.swift Sources/WhileAIWorks/GeneratedFish.swift Sources/WhileAIWorks/GeneratedPuffer.swift Sources/WhileAIWorks/GeneratedAquascape.swift Sources/WhileAIWorks/Aquarium3D.swift Tests/NativeGeneratedPufferChecks.swift \
    -o .build/native/NativeGeneratedPufferChecks
.build/native/NativeGeneratedPufferChecks
xcrun swiftc "${swift_flags[@]}" -parse-as-library -I .build/native -L .build/native -lWhileCore \
    Sources/WhileAIWorks/AppState.swift Sources/WhileAIWorks/Audio.swift Sources/WhileAIWorks/PlaySurface.swift \
    Sources/WhileAIWorks/BubbleDrawing.swift Sources/WhileAIWorks/WoodfishDrawing.swift Sources/WhileAIWorks/InteractionDrawing.swift \
    Sources/WhileAIWorks/FishingDrawing.swift Sources/WhileAIWorks/FishingGuide.swift Sources/WhileAIWorks/AquariumGlass.swift Sources/WhileAIWorks/AquariumNavigation.swift Sources/WhileAIWorks/PackedMesh.swift Sources/WhileAIWorks/GeneratedFish.swift Sources/WhileAIWorks/GeneratedPuffer.swift Sources/WhileAIWorks/GeneratedAquascape.swift Sources/WhileAIWorks/Aquarium3D.swift Sources/WhileAIWorks/AquariumPresentation.swift Sources/WhileAIWorks/AquariumView.swift Sources/WhileAIWorks/ContentView.swift \
    Sources/WhileAIWorks/MiniToo*.swift Tests/NativeFishingGuideChecks.swift -o .build/native/NativeFishingGuideChecks
.build/native/NativeFishingGuideChecks

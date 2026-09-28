#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library -emit-module -emit-library -static \
    -module-name WhileCore Sources/WhileCore/*.swift \
    -emit-module-path "$build_dir/WhileCore.swiftmodule" -o "$build_dir/libWhileCore.a"
xcrun swiftc "${swift_flags[@]}" -parse-as-library -I "$build_dir" -L "$build_dir" -lWhileCore \
    Sources/WhileAIWorks/AppState.swift Sources/WhileAIWorks/Audio.swift Sources/WhileAIWorks/PlaySurface.swift \
    Sources/WhileAIWorks/BubbleDrawing.swift Sources/WhileAIWorks/WoodfishDrawing.swift Sources/WhileAIWorks/InteractionDrawing.swift \
    Sources/WhileAIWorks/FishingSprites.swift Sources/WhileAIWorks/FishingDrawing.swift Tests/NativeMotionChecks.swift -o "$build_dir/NativeMotionChecks"
"$build_dir/NativeMotionChecks"

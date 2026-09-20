#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library -emit-module -emit-library -static \
    -module-name WhileCore Sources/WhileCore/*.swift \
    -emit-module-path .build/native/WhileCore.swiftmodule -o .build/native/libWhileCore.a
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library -I .build/native -L .build/native \
    -lWhileCore Tests/HookChecks.swift -o .build/native/HookChecks
.build/native/HookChecks
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library -I .build/native -L .build/native -lWhileCore \
    Sources/WhileAIWorks/AppState.swift Sources/WhileAIWorks/Audio.swift Sources/WhileAIWorks/CodexMonitor.swift \
    Tests/NativeHookMonitorChecks.swift -o .build/native/NativeHookMonitorChecks
.build/native/NativeHookMonitorChecks

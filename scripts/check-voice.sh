#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library -emit-module -emit-library -static \
    -module-name WhileCore Sources/WhileCore/*.swift \
    -emit-module-path "$build_dir/WhileCore.swiftmodule" -o "$build_dir/libWhileCore.a"
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library -I "$build_dir" -L "$build_dir" -lWhileCore \
    Tests/VolcanoSpeechChecks.swift -o "$build_dir/VolcanoSpeechChecks"
"$build_dir/VolcanoSpeechChecks"
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library -I "$build_dir" -L "$build_dir" -lWhileCore \
    Sources/WhileAIWorks/MiniTooVoiceAudio.swift Tests/MiniTooVoiceAudioChecks.swift -o "$build_dir/MiniTooVoiceAudioChecks"
"$build_dir/MiniTooVoiceAudioChecks"
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library -I "$build_dir" -L "$build_dir" -lWhileCore \
    Sources/WhileAIWorks/AppState.swift Sources/WhileAIWorks/Audio.swift Sources/WhileAIWorks/MiniToo*.swift \
    Tests/MiniTooVoiceViewChecks.swift -o "$build_dir/MiniTooVoiceViewChecks"
"$build_dir/MiniTooVoiceViewChecks"
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library -I "$build_dir" -L "$build_dir" -lWhileCore \
    Tests/VolcanoRealtimeChecks.swift -o "$build_dir/VolcanoRealtimeChecks"
"$build_dir/VolcanoRealtimeChecks"

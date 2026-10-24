#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library -I "$build_dir" -L "$build_dir" -lWhileCore "${agent_hud_flags[@]}" \
    Sources/WhileAIWorks/LocalAgentData.swift Sources/WhileAIWorks/LocalAgentInstallation.swift Sources/WhileAIWorks/AppState.swift Sources/WhileAIWorks/Audio.swift Sources/WhileAIWorks/AgentInteractionModels.swift \
    Sources/WhileAIWorks/AgentInteractionController.swift Sources/WhileAIWorks/AgentInteractionHooks.swift Sources/WhileAIWorks/AgentInteractionJSON.swift \
    Tests/AgentInteractionChecks.swift -o "$build_dir/AgentInteractionChecks"
"$build_dir/AgentInteractionChecks"

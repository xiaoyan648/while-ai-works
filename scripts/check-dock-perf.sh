#!/bin/bash
# Main-thread stalls while switching agents with the card open (real windows, sample data).
# `--tabs N` clicks the Codex card's tabs N times; `--real` reads this Mac's Codex and Claude data instead.
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library -I .build/native -L .build/native -lWhileCore "${rive_flags[@]}" \
    Sources/WhileAIWorks/LocalAgentData.swift Sources/WhileAIWorks/LocalAgentInstallation.swift Sources/WhileAIWorks/AppState.swift Sources/WhileAIWorks/AgentInteractionModels.swift Sources/WhileAIWorks/AgentInteractionController.swift Sources/WhileAIWorks/AgentInteractionHooks.swift Sources/WhileAIWorks/AgentInteractionJSON.swift Sources/WhileAIWorks/DesktopAgentInteraction.swift Sources/WhileAIWorks/Audio.swift Sources/WhileAIWorks/Theme.swift \
    Sources/WhileAIWorks/MascotView.swift Sources/WhileAIWorks/DesktopPet.swift Sources/WhileAIWorks/TextEditingMenu.swift Sources/WhileAIWorks/DesktopDock.swift Sources/WhileAIWorks/DesktopAgentReplyPreview.swift \
    Sources/WhileAIWorks/InteractionDrawing.swift Sources/WhileAIWorks/FishingSprites.swift \
    Sources/WhileAIWorks/AgentHubData.swift Tests/NativeDockSwitchPerf.swift -o .build/native/NativeDockSwitchPerf
.build/native/NativeDockSwitchPerf "$@"

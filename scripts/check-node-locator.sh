#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
kit="$agent_hud_root/AgentHUDCore/Providers"
xcrun swiftc "${swift_flags[@]}" -parse-as-library -I "$build_dir" -L "$build_dir" -lAgentHUDSupport \
    "$kit/Kit/Executables.swift" "$kit/Kit/ClientHome.swift" "$kit/DeepSeek/DeepSeekLocator.swift" \
    Tests/NodeLocatorChecks.swift -o "$build_dir/NodeLocatorChecks"
"$build_dir/NodeLocatorChecks"

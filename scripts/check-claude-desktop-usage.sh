#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library -D CLAUDE_DESKTOP_CHECKS "${agent_hud_flags[@]}" \
    scripts/ClaudeDesktopUsage.swift Tests/ClaudeDesktopUsageChecks.swift -o "$build_dir/ClaudeDesktopUsageChecks"
"$build_dir/ClaudeDesktopUsageChecks"
xcrun swiftc "${swift_flags[@]}" -O -parse-as-library "${agent_hud_flags[@]}" \
    scripts/ClaudeDesktopUsage.swift -o "$build_dir/while-ai-works-claude-usage"
if [[ "${1:-}" == "--live-silent" ]]; then "$build_dir/while-ai-works-claude-usage"; fi

# Agent HUD Core dependency

Unmodified `AgentHUDSupport` and `AgentHUDCore` sources from
https://github.com/jazzenchen/agent-hud-open at
`faa3a06fcf06510855ada332ea454f1f6df30ab4` (Apache-2.0).

The native app builds these modules directly with Swift 6 through
`scripts/build-agent-hud.sh`. This avoids the upstream manifest's unsupported
`SwiftSetting.swiftLanguageMode` on the current toolchain without editing upstream.
Only Codex and Claude providers are instantiated. The upstream desktop UI,
hook installation, remote sessions, other providers and demo data are not started.

Local reports and visible reply previews remain in memory. Provider account
queries use the installed clients; they never send a conversation prompt.

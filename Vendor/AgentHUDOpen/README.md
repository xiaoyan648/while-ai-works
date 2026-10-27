# Agent HUD Core dependency

`AgentHUDSupport` and `AgentHUDCore` sources vendored from
https://github.com/jazzenchen/agent-hud-open at
`faa3a06fcf06510855ada332ea454f1f6df30ab4` (Apache-2.0).

The native app builds these modules directly with Swift 6 through
`scripts/build-agent-hud.sh`. This avoids the upstream manifest's unsupported
`SwiftSetting.swiftLanguageMode` on the current toolchain without editing upstream.
Local patches: DeepSeekLocator also discovers fnm, nvm and Volta Node installations for Finder launches; the missing-runtime error describes local session decoding.
ClaudeEngineUsageClient exposes bounded authentication checks and an explicit subscription-login command through the official CLI. The CLI path decodes authentication metadata only; its authorization and credential storage remain with Claude Code. ClaudeCodeProvider now prefers a bounded desktop helper, which reads existing encrypted Desktop OAuth state without modifying it. The helper returns quota and account metadata only; background reads prohibit Keychain UI. Desktop credential permission and new CLI login are separate explicit user actions. The missing-login message no longer claims the desktop app signed out.

Only Codex and Claude account providers are instantiated. DSH local transcript decoding is also used. The upstream desktop UI,
hook installation, remote sessions, other providers and demo data are not started.

Local reports and visible reply previews remain in memory. Provider account
queries use the installed clients; they never send a conversation prompt.

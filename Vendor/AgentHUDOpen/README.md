# Agent HUD Core dependency

`AgentHUDSupport` and `AgentHUDCore` sources vendored from
https://github.com/jazzenchen/agent-hud-open at
`faa3a06fcf06510855ada332ea454f1f6df30ab4` (Apache-2.0).

The native app builds these modules directly with Swift 6 through
`scripts/build-agent-hud.sh`. This avoids the upstream manifest's unsupported
`SwiftSetting.swiftLanguageMode` on the current toolchain without editing upstream.
Local patches: DeepSeekLocator also discovers fnm, nvm and Volta Node installations for Finder launches; the missing-runtime error describes local session decoding.

Only Codex and Claude account providers are instantiated. DSH local transcript decoding is also used. The upstream desktop UI,
hook installation, remote sessions, other providers and demo data are not started.

Local reports and visible reply previews remain in memory. Provider account
queries use the installed clients; they never send a conversation prompt.

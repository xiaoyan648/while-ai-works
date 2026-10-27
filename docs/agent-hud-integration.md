# Agent HUD 数据接入

参照 [jazzenchen/agent-hud-open](https://github.com/jazzenchen/agent-hud-open)，固定提交 `faa3a06fcf06510855ada332ea454f1f6df30ab4`。`Vendor/AgentHUDOpen` 保留 Support / Core 和 Apache-2.0 许可；本地适配记录在该目录的 README 中，应用资源包含许可证。界面由本项目原生实现。

## 已接入

`AgentHubDataController` 只组合 Codex / Claude providers。使用内存 ledger；未启动其他 providers、上游 Desktop UI、远程 relay 或自动安装 hooks，也不使用 demo assembly。

`UsageReport` 映射为本项目 DTO，分别展示账户剩余额度、会话 tokens、明确的 turn 状态、可见回复及原会话入口。`UsageStore.observeChanges` 驱动实时更新，手动刷新会触发客户端账户查询。关闭回复立即清除 UI DTO 正文。

Codex IPC 使用原始 `CodexDesktopIPC` 的 UID/socket 校验、限时帧协议和 owner snapshot。原客户端当前版本的 start-turn v2 / steer-turn v1 已通过本机应用源码确认。发送由用户操作触发；拒绝、未连接和结果不确定分别表达，不自动重试。未知 turn store / runtime 状态不提交。

Claude 原会话入口使用 provider 给出的 native destination；没有入口时只复制安全 UUID 恢复命令。任意运行中 Claude 会话的直接输入尚未支持。官方 [CLI 参考](https://code.claude.com/docs/en/cli-reference) 与 [agent view](https://code.claude.com/docs/en/agent-view) 提供恢复、attach 和原客户端 peek/reply；这些能力不能被当成通用本机输入 API。

## 待处理请求桥接

`AgentInteractionController` 直接复用未修改的上游 `CodexDesktopPermissions`，保留原 owner、原问题 ID、原 turn 的身份校验与精确回执。后台读取采用两秒基础间隔与读取耗时十倍休息期；失败读取保留请求并禁用回答，不将断线当作已解决。发送回执确认后仍保留角标，等原 owner 明确撤回请求。

`AgentInteractionHookServer` 和应用包内 `while-ai-works-agent-interaction` 是本应用的独立 Hook 通道，借鉴上游 Unix socket 生命周期、Claude 问题回答格式和追加记录监听。原 SDK 未修改；本应用拥有独立 socket、handler 名称和配置安装器，不占用 Agent HUD 的 socket 或接管其 handler。Codex Hook 按上游规则核对同轮次 `approvals_reviewer: user`，不拦截自动审核。Claude 支持 `AskUserQuestion` 的单选、多选、自由输入；`ExitPlanMode` 返回原客户端。

安装是设置中的显式操作，不随 provider 启动而自动修改配置。配置更新先以私有临时文件写入，保留原权限、核对配置未并发改变后原子替换；未知格式不重写。保留其他 hooks、环境与权限模式。Hook 传输完成只表示交还客户端，不声称工具成功执行。隔离检查使用假 owner 和假 Hook payload，不提交真实权限决策。

## Claude 登录复用与额度查询

Claude 额度优先复用桌面端已有订阅登录，其次使用本机 Claude Code 的 `get_usage` 控制请求。两条路径均不发送模型提示词。会话与 tokens 仍读本地记录；API key 或中转站登录不等同于订阅额度。

桌面路径由独立的 `while-ai-works-claude-usage` helper 读取 Claude `config.json` 的加密 OAuth 缓存和 Cookies 中的当前组织。仅选择当前账户、当前组织、生产 API 主机及 Code 所需 scope 的未过期 token；新版缓存的撤销记录覆盖旧版。通过系统钥匙串取得 Safe Storage 密钥，在子进程内解密，查询桌面客户端使用的 `https://api.anthropic.com/api/oauth/profile` 和 `/api/oauth/usage`，确认远端账户身份，并在查询后复核本地身份。禁止重定向，限制响应大小和耗时。helper 仅返回额度与账户标识，不输出或保存 token、刷新 token、Cookie 或密钥，也不修改 Claude 登录文件。过期 token 交由 Claude 自己刷新；本应用不轮换其 refresh token。

启动、关注/交互监听开关变化、启动猫条以及前台重新激活时只做静默检测。后台 helper 禁用 macOS 旧式钥匙串交互，并使用禁止 UI 的读取参数；即使读取卡住，也会被父进程限时结束。连接检测和额度采集共用一分钟缓存和进行中的请求。桌面端不可用时尝试 Claude Code，只有两者都没有可用登录时才出现手动登录入口。

若系统阻止读取已有桌面登录，在设置与猫条用量页显示“复用 Claude 桌面登录”；仅点击此按钮才允许系统钥匙串授权。这是读取已有登录的授权，不是重新登录 Claude。若需要后台持续刷新，可在系统提示中选择“始终允许”；只允许一次时，之后的静默访问仍可能被拒绝。没有可复用登录时，“登录 Claude 订阅”按钮才启动官方 `claude auth login --claudeai` 浏览器流程。授权、登录、取消与重新检测均为明确的手动操作；启用监听不会打开授权窗口。网络失败、权限不足、凭据过期分别显示，不误报桌面端退出登录。

桌面缓存与额度端点是当前客户端的实现接口，并非承诺稳定的公开第三方 API。格式变化时停止该读取并回退官方 CLI；不把历史用量或账户计划资料当成实时额度。实现参考见 [Claude 桌面登录复用验证](claude-desktop-reuse.md)。

Codex 的状态、回复和会话 tokens 来自本地 `sessions` / `archived_sessions`。账户额度另经本机官方 `codex app-server --listen stdio://` 的 `account/rateLimits/read` 获取，会由官方客户端联网刷新；应用不自行提取 Codex token 拼装 HTTP 请求。该方法在 [OpenAI 官方 App Server 文档](https://learn.chatgpt.com/docs/app-server) 中公开。当前 provider 自动查询约 300–360 秒一次，collector 限制手动账户刷新最小间隔 60 秒。额度查询不发起模型 turn，但公开接口与低频查询不构成账户风控的零风险保证。

## 验证边界

`check-agent-data.sh` 验证剩余量语义、失效读数、重置时间、缓存维度、预览隐私、UUID 入口、canonical turn / idle / malformed 状态，以及原 owner 回执匹配。不会输出真实凭据。

`check-claude-subscription.sh` 验证静默启动/开关、仅手动授权、桌面优先与 CLI 回退、请求去重、失败及子进程清理。`check-claude-desktop-usage.sh` 使用加密 fixture、SQLite Cookie fixture 和模拟 HTTP 响应验证账户隔离、过期/撤销、查询及输出不含凭据；`--live-silent` 只执行无弹窗的本机读取。`check-ui.sh --claude-subscription` 渲染设置和猫条的登录复用、等待、失败与缺少登录状态。真实系统钥匙串授权只能由用户在设置或用量页手动触发。

`--ipc-probe <thread-uuid>` 可读取真实 owner snapshot 并准备请求，**不会提交**。原会话能力以当前 owner snapshot 为准。没有向用户正在运行的会话发送测试消息；因此真实消息送达端到端尚未验收。

上游 manifest 在本机 SwiftPM 中报 `SwiftSetting.swiftLanguageMode` 不可用。直接用 Swift 6 编译模块，构建缓存按完整源文件哈希及目标架构更新，无需修改 manifest。

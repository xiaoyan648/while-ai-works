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

## Claude 官方引擎查询

Claude 额度沿用 `ClaudeCodeProvider.standard`：启动本机 `claude`，以 stream-json 向引擎发出 `get_usage` 控制请求。查询关闭 hooks，不发送模型提示词；引擎自行处理登录和联网。会话与 tokens 仍读本地记录。应用不包含桌面钥匙串解密或直接请求订阅 HTTP 端点的备用路径。

启动应用、修改 Claude 关注/交互监听开关、启动猫条及修改 Claude 接入配置时，以额度查询相同的引擎和环境运行 `claude auth status --json`。没有登录时，在设置和猫条额度页提供“登录 Claude 订阅”；点击后才运行官方 `claude auth login --claudeai`，由用户完成浏览器授权。成功退出后再次确认登录，再重建数据采集以立即读取额度，避免旧的未登录结果与一分钟查询间隔阻碍刷新。检查失败、未登录、非订阅登录、登录失败和超时分别显示；取消、关闭关注或退出应用会结束本应用启动的登录子进程。前台重新激活及手动检测也可识别外部终端完成的登录。

切换 API 供应商和完成 Claude 订阅登录是两步；`--console` 是 API 计费。没有自动导入终端环境 token 或桌面端凭据；用户的环境和登录目录保持原样。复制的终端登录命令使用相同的引擎路径与配置目录。若应用继承了中转站环境，命令行登录也未必能提供订阅额度；不要把桌面 App 的 Pro 资料或仅 `loggedIn: true` 当作额度已可读取的证据。

Codex 的状态、回复和会话 tokens 来自本地 `sessions` / `archived_sessions`。账户额度另经本机官方 `codex app-server --listen stdio://` 的 `account/rateLimits/read` 获取，会由官方客户端联网刷新；应用不自行提取 Codex token 拼装 HTTP 请求。该方法在 [OpenAI 官方 App Server 文档](https://learn.chatgpt.com/docs/app-server) 中公开。当前 provider 自动查询约 300–360 秒一次，collector 限制手动账户刷新最小间隔 60 秒。额度查询不发起模型 turn，但公开接口与低频查询不构成账户风控的零风险保证。

## 验证边界

`check-agent-data.sh` 验证剩余量语义、失效读数、重置时间、缓存维度、预览隐私、UUID 入口、canonical turn / idle / malformed 状态，以及原 owner 回执匹配。不会输出真实凭据。

`check-claude-subscription.sh` 验证启动/开关触发、检查和登录去重、登录后刷新、外部登录、失败/超时及子进程清理；使用隔离假 CLI，不替用户登录。`--live-auth-probe` 只报告本机检测状态。`check-ui.sh --claude-subscription` 渲染设置和猫条的登录入口、等待、失败与缺少引擎状态；真实浏览器授权和订阅额度仍需登录后验收。

`--ipc-probe <thread-uuid>` 可读取真实 owner snapshot 并准备请求，**不会提交**。原会话能力以当前 owner snapshot 为准。没有向用户正在运行的会话发送测试消息；因此真实消息送达端到端尚未验收。

上游 manifest 在本机 SwiftPM 中报 `SwiftSetting.swiftLanguageMode` 不可用。直接用 Swift 6 编译模块，构建缓存按完整源文件哈希及目标架构更新，无需修改 manifest。

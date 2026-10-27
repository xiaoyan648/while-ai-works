# Hermes / DSH 增强监听

工作状态与 Token 默认从本机读取，API Key 或自定义网关无需提供账户额度。
增强监听补充准确的工作生命周期、子 Agent 归属和待处理状态；不会保存对话、回答、命令或凭据。
本应用只导出自己的扩展，安装与启用在原客户端完成。

## DSH

安装按钮已复制命令。检测到 `dst` 的 `dsh-tui` profile 时默认选择它，否则选择 `web`。请核对实际使用的 profile；`tui` 和 `dsh-tui` 是两个独立安装。
本机验证版本：0.2.1-rc.2。启用后重启该 profile。
支持普通结构化问题、带完整工具参数的单次允许/拒绝。计划审阅、限时问题及无法确认参数的审批会显示待处理提醒，回答仍在原客户端完成；取消或处理后撤回提醒。
Otty / iTerm2 中的本地 DSH 会话可跳回原终端面板。每次点击重新校验该会话的进程锁；原会话已退出或终端未提供定位标识时，复制恢复命令，保留已知 profile。
小猫关闭、未关注 DSH、断开或等待超时后交回原客户端；不自动批准。
使用 `dst` 时安装：`dsh plugin --profile dsh-tui add "$HOME/Library/Application Support/While AI Works/Integrations/dsh"`，然后重启对应客户端。
移除：`dsh plugin --profile dsh-tui remove dsh-while-ai-works`（其他客户端替换 profile），然后重启。

## Hermes

执行复制的命令，将插件安装到当前 `HERMES_HOME`，再重启 Hermes。
本机真实验证版本：v0.22.5。已启动的 gateway 会保留启动时的环境，安装插件或更改交互通道后也需重启 gateway。
支持 CLI/gateway 的轮次状态、完成、等待输入提醒。需要 Hermes 版本提供相应生命周期 hooks。
问题和密码在原客户端回答。

工具审批另外使用 Hermes 官方 approval transport。仅在希望由猫条回答审批时，合并下列配置到当前 Hermes config.yaml；保留其他配置：

```yaml
security:
  approval:
    transport: while-ai-works
    transport_fallback: builtin
```

未配置 transport 仍可跟随状态。插件只提供一次允许或拒绝，Hermes 仍决定哪些工具需要审批、请求是否有效及如何处理超时。
Hermes 的智能审批可能直接放行安全操作，这时不会产生待确认卡片。需要逐项人工确认的体验，可在 Hermes 中设置 `hermes config set approvals.mode manual` 后重新开始会话。
移除：`hermes plugins disable while-ai-works`，恢复原 transport 配置并重启。

## 反馈

请记录客户端版本、profile、登录方式、复现步骤、预期与实际状态。
不要发送 API Key、完整会话日志或原始配置；可提供脱敏后的事件类型、时间、计数和截图。
账户额度缺失不会显示为 0%，也不会阻止工作状态和本机 Token。

# AI 事件监听

当前本地版本支持同时跟随 Codex、Claude Code、Qoder、WorkBuddy，默认全选。「设置 → 跟随 AI」可分别勾选；菜单栏共用选择。也可以切换「随时开启」。全不选表示没有工作，不等于随时开启。旧版单选首次迁移为全选，但保留原先明确选择的随时开启模式。

各客户端会话数分别统计，再求和；总数大于零即工作中。一个来源结束不会清掉另一个来源；木鱼仍是整体工作期间每 5 秒减 1，不按客户端数倍增。繁忙度累加已选且工作中的来源活跃度，并限制在 0–1。

## 安装

1. 将 `While AI Works.app` 放入「应用程序」并启动。
2. 在「设置 → 跟随 AI」把「什么时候」设为「跟随 AI 工作」，勾选需要的客户端（可多选，默认全选）。
3. 在同一处点击对应客户端的「安装监听」。应用将原生辅助程序复制到 `~/Library/Application Support/While AI Works/Hooks/while-ai-works-hook`，并合并客户端的用户级配置。
4. 重启客户端。如果客户端提示审核新增 Hooks，请在客户端完成审核。开始新任务，再点击本应用「开始玩」。
5. 只是不想跟随时取消勾选即可；彻底卸载时，在「设置 → 跟随 AI」点击对应客户端的「移除」，然后重启客户端。移除保留其他配置和 Hooks。不要直接用旧备份覆盖后来增加的其他设置。

| 来源 | 接入位置 | 方式 |
| --- | --- | --- |
| Codex | `$CODEX_HOME/sessions`，默认 `~/.codex/sessions` | 只读任务生命周期日志，无需安装 |
| Claude Code | `~/.claude/settings.json` | 官方 Hooks，本机终端 / IDE 的 Claude Code 会话 |
| Qoder | `~/.qoder/settings.json` | 官方 Hooks |
| WorkBuddy 桌面端 | `~/.workbuddy/settings.json` | 桌面端 Hooks，已核对本机客户端实现 |

Qoder CN / 通义版使用不同的 `.lingma` 配置目录，本版未接入。WorkBuddy 网站的 CodeBuddy CLI 文档使用 `.codebuddy`；本版针对 WorkBuddy 桌面端，不修改 `.codebuddy`。

安装/移除会在配置旁保存带 UUID 的 `.bak` 原文件。配置无法安全解析时拒绝覆盖。重复安装不会重复注册。应用不会打开客户端禁用的 Hooks，也不会绕过客户端审批。

## 事件和隐私

监听 `UserPromptSubmit`、`PreToolUse`、`PostToolUse`、`Stop`、`SessionEnd`。开始与工具活动标记工作，Stop/SessionEnd 标记结束；子代理结束不会结束主会话。WorkBuddy 按稳定的 session_id 更新会话状态；其 generation_id 实际是模型消息 ID，同一轮任务内会变化，因此不作为过滤条件。Qoder 保留原有轮次校验。

辅助程序通过标准输入接收客户端事件，在内存中提取必要字段。磁盘只保留 SHA-256 会话/轮次标识、状态、时间和计数；不保留会话原文、目录、工具名或参数，不连接网络。文件仅当前用户可读。辅助程序始终无输出、成功退出，不干预 AI 决策；事件输入限 1 MB。

安装后的 Hooks 即使解压应用退出也会更新少量本地状态，直到移除监听；每个会话只保留最新状态，写入时清理超过一天的旧文件。关闭桌面效果会停止应用轮询。5 分钟没有有效事件的工作状态视为空闲，防止客户端崩溃后一直工作。超过 5 分钟的纯思考或单次工具调用可能暂时显示空闲，下一次有效工具事件会恢复工作；等待权限、取消但客户端未发 Stop 的情况也可能不准确；不把事件频率称为 token/s。

Codex 的既有读取方式与 Hooks 不同：它经过包含对话的本地日志，但不保存或上传对话。首次读取历史不计为当前活跃度。Codex 与 Hooks 均使用 5 分钟无有效事件兜底。Codex 的 `item_completed` 事件携带稳定的 turn_id，可用于恢复读取尾部遗漏的开始事件；已结束轮次不会被该轮的迟到进度重新激活。静默生命周期元数据最多在内存保留一天，以支持旧格式日志在恢复活动时重新计入工作。

## 验证范围

`./scripts/check-hooks.sh` 使用临时目录和独立偏好域，验证开始/结束、多会话、来源隔离、旧轮次事件、隐私字段过滤、超时、配置备份、重复安装、卸载保留其他配置，以及真实 AppState + 监听器的状态流转与 Codex 回归。

自动化测试使用协议样本与本地集成，不等于所有客户端版本的真实任务验收。需要支持 Hooks 的客户端版本；配置被禁用、项目策略或客户端审批拦截时需在对应客户端处理。没有事件时仍可用「随时开启」。

## 依据

- [Qoder Hooks](https://docs.qoder.com/zh/extensions/hooks)
- [WorkBuddy Enterprise Hooks](https://cloud.tencent.com/document/product/1831/134517)
- [WorkBuddy 文档中的 CodeBuddy CLI Hooks](https://www.workbuddy.ai/docs/zh/cli/hooks)

## 简化的状态模型

每个来源维护独立的、按会话 ID 去重的状态集合（不同来源即使 ID 相同也不冲突），每个会话只保留工作状态、最后有效事件时间和累计事件计数。工作数量是未过期且 working=true 的会话数；大于零即有 AI 在工作。开始或工具事件将该会话设为工作中，Stop/SessionEnd 将它设为空闲，重复开始或结束不会改变其他会话。每个会话独立在 5 分钟无有效事件后过期。取消勾选的来源不贡献工作数量或繁忙度；其他来源的读取游标保留，避免重放历史。异步结果使用配置版本校验，防止快速切换后旧结果覆盖新选择。

繁忙程度与工作数量分开：应用根据最近 15 秒的新增事件数、按约 5 秒指数衰减估算活跃度，工作时保留低档基础值。这里没有可靠的 token 增量，不将该值表示为 token/s。

WorkBuddy 依赖同一会话按客户端实际发送顺序报告生命周期；客户端若漏发 Stop，使用 5 分钟兜底。同一会话若出现跨轮乱序且没有稳定轮次 ID，现有字段不足以准确区分，不伪造轮次保证。

客户端版本变化后，请重新验证开始、工具活动、结束与空闲状态。

## Claude Code

在「设置 → 跟随 AI」勾选 Claude Code，点击「安装监听」，然后重启 Claude Code 会话。既有客户端选择保持不变，升级用户需自行勾选新增项。

除通用生命周期事件外，接收 `PostToolUseFailure` 以继续跟随工具失败后的工作，接收 `StopFailure` 以在 API 错误结束时回到空闲。按 `session_id` 分别统计多个会话；忽略 `SubagentStop`，避免子代理结束清除主任务。只保留哈希标识、状态、时间、计数和阶段，不保存对话或工具参数。五分钟无事件回到空闲。

此功能是工作状态监听，不是 token / 额度统计，也不监听 Claude 普通聊天。当前安装器使用默认 `~/.claude/settings.json`；自定义 `CLAUDE_CONFIG_DIR`、远端或沙箱中的会话不在自动安装范围内。自动化用例不替代真实客户端端到端验收。

参考：[Claude Code 官方 Hooks 文档](https://code.claude.com/docs/en/hooks)。

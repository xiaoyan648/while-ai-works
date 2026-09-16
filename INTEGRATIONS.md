# AI 事件监听

0.14.0 支持随时开启、Codex、Qoder、WorkBuddy 四种来源。每次跟随一个来源，多个会话中只要仍有一个工作，效果就继续；菜单栏和设置共用选择。木鱼扣减、玩法轮换和来鱼速度跟随同一状态。

## 安装

1. 将 `While AI Works.app` 放入「应用程序」并启动。
2. 设置「什么时候」为「跟随 Qoder」或「跟随 WorkBuddy」。
3. 点击「安装监听」。应用将原生辅助程序复制到 `~/Library/Application Support/While AI Works/Hooks/while-ai-works-hook`，并合并客户端的用户级配置。
4. 重启客户端。如果客户端提示审核新增 Hooks，请在客户端完成审核。开始新任务，再点击本应用「开始玩」。
5. 不再使用时，选择对应客户端并点击「移除」，然后重启客户端。移除保留其他配置和 Hooks。不要直接用旧备份覆盖后来增加的其他设置。

| 来源 | 接入位置 | 方式 |
| --- | --- | --- |
| Codex | `$CODEX_HOME/sessions`，默认 `~/.codex/sessions` | 只读任务生命周期日志，无需安装 |
| Qoder | `~/.qoder/settings.json` | 官方 Hooks |
| WorkBuddy 桌面端 | `~/.workbuddy/settings.json` | 桌面端 Hooks，已核对本机客户端实现 |

Qoder CN / 通义版使用不同的 `.lingma` 配置目录，本版未接入。WorkBuddy 网站的 CodeBuddy CLI 文档使用 `.codebuddy`；本版针对 WorkBuddy 桌面端，不修改 `.codebuddy`。

安装/移除会在配置旁保存带 UUID 的 `.bak` 原文件。配置无法安全解析时拒绝覆盖。重复安装不会重复注册。应用不会打开客户端禁用的 Hooks，也不会绕过客户端审批。

## 事件和隐私

监听 `UserPromptSubmit`、`PreToolUse`、`PostToolUse`、`Stop`、`SessionEnd`。开始与工具活动标记工作，Stop/SessionEnd 标记结束；子代理结束不会结束主会话。WorkBuddy 提供 generation_id 时，旧一轮的 Stop 不会终止新一轮。

辅助程序通过标准输入接收客户端事件，在内存中提取必要字段。磁盘只保留 SHA-256 会话/轮次标识、状态、时间和计数；不保留会话原文、目录、工具名或参数，不连接网络。文件仅当前用户可读。辅助程序始终无输出、成功退出，不干预 AI 决策；事件输入限 1 MB。

安装后的 Hooks 即使解压应用退出也会更新少量本地状态，直到移除监听；每个会话只保留最新状态，写入时清理超过一天的旧文件。关闭桌面效果会停止应用轮询。20 分钟没有事件的工作状态视为断开，防止客户端崩溃后一直工作。长时间纯思考、等待权限、取消但客户端未发 Stop 的情况可能不准确；不把事件频率称为 token/s。

Codex 的既有读取方式与 Hooks 不同：它经过包含对话的本地日志，但不保存或上传对话。首次读取历史不计为当前活跃度。

## 验证范围

`./scripts/check-hooks.sh` 使用临时目录和独立偏好域，验证开始/结束、多会话、来源隔离、旧轮次事件、隐私字段过滤、超时、配置备份、重复安装、卸载保留其他配置，以及真实 AppState + 监听器的状态流转与 Codex 回归。

这是官方协议模拟与本地集成测试，不等同于在两个客户端里分别真实运行任务。需要支持 Hooks 的客户端版本；配置被禁用、项目策略或客户端审批拦截时需在对应客户端处理。没有事件时仍可用「随时开启」。

## 依据

- [Qoder Hooks](https://docs.qoder.com/zh/extensions/hooks)
- [WorkBuddy Enterprise Hooks](https://cloud.tencent.com/document/product/1831/134517)
- [WorkBuddy 文档中的 CodeBuddy CLI Hooks](https://www.workbuddy.ai/docs/zh/cli/hooks)

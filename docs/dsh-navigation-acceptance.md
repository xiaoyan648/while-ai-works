# DSH 原会话跳转与确认提醒验收

验收日期：2026-10-27。环境：macOS、Otty 1.6.2、DSH 0.2.1-rc.2、dsh-TUI 0.17.0。
本机安装版本为 `0.20.2-local.2`（build 39），未发布公开版本。

## 修复范围

- 按 DSH 会话锁的存活进程读取终端定位标识，显示返回原面板的箭头；点击时重新校验。原进程退出后提供恢复命令，并保留已知 profile。
- `dst` 实际使用 `dsh-tui`，安装入口检测到该 profile 后优先选择它。本机已将监听包加入该 profile 的 dependencies 和 bundles。
- 普通问题、工具审批、计划审阅、限时问题及缺少工具参数的请求均登记等待状态。只能在原客户端处理的请求也显示提醒和跳转入口。新会话尚未写出日志时仍可显示请求；已取消请求不会重新转交原客户端弹出。

## 实际客户端验收

通过临时验收插件调用真实 DSH 的问题与审批服务，在 Otty 中运行真实 `dst`，再通过 macOS 原生界面点击猫条。验收不调用模型，也不执行审批示例中的工具命令。

| 场景 | 结果 |
| --- | --- |
| 正在运行的原工作会话 | 点击“回到原会话”后，Otty 选中与该会话锁关联的原标签，标签 ID 完全匹配 |
| 计划审阅 | 猫条显示“待你处理”和“计划待审，请到原会话处理”；点击箭头打开该请求所在的原标签；原客户端答复后提醒撤回 |
| 普通确认问题 | 猫条选择“验证通过”并提交；DSH 返回对应问题 ID 的结构化答案 |
| 工具审批 | 猫条显示工具名、参数和原因；点击“拒绝”后 DSH 返回 `rejected` |
| 请求取消 | 猫条提醒撤回，DSH 返回 `ASK_ABORTED`；原客户端没有重新弹出问题 |
| 验收进程退出 | 会话跳转箭头回退为恢复命令，无残留待处理提醒 |

实际交互证据保存在本地忽略目录 `.build/dsh-navigation-acceptance/`，包括 `original-session-jump.json`、`jump-result.json`、`question-answered.json`、`approval.json`、`question-cancelled.json`。临时终端已关闭，验收日志已移出 DSH 会话目录归档，显示屏设置已恢复。

## 自动检查与安装核对

以下检查通过：

- `scripts/check-local-agents.sh`：进程定位、失效入口、无日志请求、真实 Node → Swift socket 往返与取消。
- `Tests/LocalAgentBridgeChecks.mjs`：真实 Cordis 分发下的问题、单次允许/拒绝、原生计划/限时/详细问题、缺参审批、并发等待、取消及元数据隐私。
- `scripts/check-agent-data.sh`、`scripts/check-agent-interactions.sh`、`scripts/check-desktop-dock.sh`。
- `scripts/build.sh`、安装包签名验证、`git diff --check`。
- 源码、已安装 App 资源和已导出的监听插件 SHA-256 一致；设置界面显示已收到 DSH 增强监听事件。

Otty 跳转已做实机验证；iTerm2 定位格式通过解析检查，未做 iTerm2 实机验收。

## 原工作会话重启后复测

在用户授权发布后，确认原工作会话已经完成且没有待处理请求，正常退出 `dst`，在原 Otty 面板通过 `dst --resume` 恢复同一个会话。原上下文保留，新进程启动时间晚于最终插件更新，确认已加载最新监听。

在该原会话发起一次只调用 `ask_user_question` 的真实模型验收，不执行项目命令或修改文件。猫条显示“DSH 重启后确认提醒验收”和两个选项；先切到其他 Otty 标签，再点击猫条箭头，准确返回原标签。在猫条提交“验证通过”后，原客户端显示对应问题已答并回复“确认回传正常”，猫条撤回提醒。

复测证据保存在本机 `.build/dsh-restart-release/`。发布记录见 [0.20.2 发版验证](releases/0.20.2-validation.md)。

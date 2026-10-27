# Hermes / DSH 本地验收说明

本次增加 Hermes 与 DeepSeek Harness（DSH）的工作状态、会话列表、本机 Token 和可验证的待处理交互。账户额度与本机会话用量分别处理：API Key 不代表没有 Token，但不能据此推算账户剩余额度。Hermes / DSH 不展示账户额度、空进度环或余额百分比，也不读取 API Key 发起额度查询。

## 能力与边界

| 能力 | Hermes | DSH |
| --- | --- | --- |
| 猫条入口、设置开关、工作动画 | 支持 | 支持 |
| 会话与本机 Token | 只读 state.db，兼容 profiles 和按模型用量表 | 读取会话日志，包括 v4 JSONL / Zstandard |
| 准确的工作开始、完成、等待 | Gateway 提供聚合工作数；增强监听补充会话生命周期 | 日志轮次 + 该会话的真实进程锁；增强监听补充等待 |
| 子 Agent | 按真实委托关系归属，压缩后的前后会话不当作父子 | 增强监听写入明确的父会话关系 |
| 继续会话 | 复制包含原数据目录的恢复命令 | Otty / iTerm2 按存活会话的进程定位原面板；不可定位时复制包含原数据目录、已知 profile 的恢复命令 |
| 猫条回答问题 | 提醒后回原客户端回答 | 普通结构化问题，支持选项、多选、补充文本 |
| 猫条工具审批 | 显式启用官方 transport 后，一次允许或拒绝 | 有准确工具名和参数时，一次允许或拒绝 |
| 回复预览、猫条主动发新消息 | 本次未接入 | 本次未接入 |
| 账户剩余额度 | 隐藏 | 隐藏 |

Hermes 已在本机安装官方稳定版 v0.22.5，并完成真实 CLI/gateway、轮次状态、Token 和审批拒绝验证。具体证据见文末本机验收记录。

DSH 已在本机 0.2.1-rc.2 上验证。限时问题依赖原客户端的等待租约，计划审阅还包含额外内容，这两类继续使用原客户端，但会在猫条显示待处理提醒。缺失完整工具参数时同样显示提醒，交回原客户端审批。限时问题超时后仍可回答时，跟随官方会话投影保留提醒；回答、取消或进程退出后撤回。不自动批准。上游接口仍可能变化，版本不匹配应停止增强交互而保留可读的本地数据。

## 数据如何到达界面

1. 独立后台任务每两秒读取 Hermes SQLite 与 DSH 日志，合并到现有会话模型。账户接口慢不会阻塞这条链路。
2. Hermes Gateway 只有进程 PID、启动时间、服务状态与 active_agents 均符合时才报告工作。心跳更新时间本身不会触发工作，也不会单独结束长任务。CLI 会话的文件更新时间不当作正在工作。
3. DSH 只有明确的轮次开始和该会话仍被进程持有的锁才保持工作状态；仅仅启动 Harness、刷新文件或修改会话标题不会使它工作。明确的完成事件才产生完成标记。
4. 可选扩展仅写会话 ID、父子归属、PID/启动时间与状态时间，不保存对话、回答、工具参数或密钥。审批所需的完整命令/参数通过当前用户的私有 Unix socket 临时交给 App 展示。
5. 请求携带随机撤回标识、所属进程 PID/启动时间与有效期。取消任务会撤回卡片；进程退出或请求到期后卡片也失效，提交前再次检查。
6. 用户回答后，DSH 收到保留原问题 ID 的结构化答案；Hermes 收到绑定当前请求 ID 与摘要的一次性决定。App 显示“已交给原客户端”，不把 socket 写入成功描述为工具执行成功。

例子：DSH 开始任务，App 显示“工作中”；模型暂时没有输出但进程仍持有会话锁，动画继续。它提出普通问题时，卡片显示待处理。用户作答后 DSH 继续，最后写入 completed 事件，App 才显示完成与本机 Token。若中途杀掉进程，锁失效后停止工作动画，不冒充成功完成。

## 安装与本机验收

在 App 设置的“关注的 Agent”中开启 Hermes / DSH，再点“配置…” → “导出插件与接入说明”。按钮导出扩展、打开说明并复制命令；不会改写现有客户端配置。检测到 `dst` 的 `dsh-tui` profile 时默认选择它，否则选择 `web`。`tui` 和 `dsh-tui` 是两个独立安装。按 [扩展安装说明](../Sources/WhileAIWorks/Resources/LocalAgents/README.md) 核对实际 profile，安装并重启客户端。自定义 HERMES_HOME / DSH_HOME 用户需把相同环境传给 App；默认扫描 ~/.hermes、其 profiles 和 ~/.dsh。

本地 Preview 使用独立偏好设置，关闭游戏和声音，不启动自动更新。为避免两个实例争用交互 socket，先退出当前正式版，再打开 Preview；首次打开同时展示 Codex、Claude、Hermes、DSH，之后保留 Preview 自己的关注设置。

本地构建：`bash scripts/build-local-preview.sh`，产物在 `dist/While AI Works Preview.app`。这是使用独立偏好设置的本机 ad-hoc 签名体验包。正式版本的支持范围见 [0.20.0 发布说明](releases/0.20.0.md)。

验收建议按以下顺序执行：

1. 不运行任务时启动 CLI/gateway，猫不应误判忙碌。开始普通任务，检查开始与完成动画；执行长任务时检查静默阶段不掉成空闲。
2. 开两个会话，检查数量、标题与目录。启动子 Agent，检查父子归属，结束一个会话不应影响另一个。
3. 普通任务结束后对比客户端本机 Token。重开卡片、重启 App，不应重复累计；没有 Token 的会话不应出现伪造的账户额度。
4. DSH 提问时验证选项、多选和文本回答；Hermes 提问回原客户端。审批分别点允许与拒绝，核对工具与完整参数。
5. 等待问题/审批时取消任务、退出 App、取消关注客户端，确认不误提交，原客户端能够继续接管。
6. 检查 Codex / Claude 的会话、额度与原交互是否正常。

反馈只需客户端版本、profile、步骤、预期/实际结果及脱敏截图。不要上传 API Key、完整日志或原始配置。

## 自动验证

运行前先执行 `bash scripts/build.sh`。Swift 检查脚本共用构建目录，按顺序运行：

```sh
bash scripts/check-local-agents.sh
bash scripts/check-agent-data.sh
bash scripts/check-agent-interactions.sh
bash scripts/check-hooks.sh
bash scripts/check-desktop-dock.sh
bash scripts/check-desktop-pet.sh
```

扩展专项检查：

```sh
# 指向本机 DSH 使用的实际 Cordis lib/index.js
DSH_CORDIS_PATH=/path/to/cordis/lib/index.js node Tests/LocalAgentBridgeChecks.mjs
# 指向所验证 Hermes 源码中的 hermes_cli/approval_transport.py
HERMES_TRANSPORT_CONTRACT=/path/to/hermes_cli/approval_transport.py python3 -B Tests/HermesBridgeChecks.py
# 真实 DSH 安装/运行，隔离 DSH_HOME，模型只连接本机模拟服务
python3 Tests/DSHRuntimeCheck.py
```

DSH 运行检查使用真实安装的 headless 客户端，在临时 profile 安装扩展；Swift 读取其实际压缩日志并验证工作中、完成、Token。它不证明远端模型、个人账号或 Web/TUI 的全部行为已验收。Hermes 契约检查也不等同于完整客户端验收。

## 2026-10-24 本机真实模型验收

DSH 0.2.1-rc.2 沿用已有 Magpie 接入和 `tokenzz/deepseek-v4.1-flash` 模型，已把增强监听安装到 headless、web、tui 三个现有 profile。以下实测使用 headless，确实调用模型：

- 执行 `sleep 12` 后打印验收标记；Preview 猫条观察到工作状态和完成标记，本地读取器读到输入 12,191、输出 157 Token。
- 通过实际 `ask_user_question` 工具提出选项问题，安装的扩展交给生产 Swift 交互服务，回传选项后模型继续完成任务。headless 默认不挂载提问工具，因此仅本次测试额外加载了该官方工具插件；web/tui 的原配置保留。
- 实际 bash 工具提出扩大沙箱权限的审批，Swift 交互服务拒绝；DSH 确认命令未执行、未重试。
- 另一条真实问题由正在运行的 Preview 接收，猫条显示待处理数量；取消 DSH 后提示撤回。自动化无法定位独立的工作卡片窗口，所以鼠标点击回答的体验仍需人工验收。

测试日志保存在本机 `.build/live-acceptance/`，不随代码发布。上述为发布前的本机验收记录；正式版打包与更新验收见 [0.20.0 发版验证](releases/0.20.0-validation.md)。

Hermes 使用官方稳定版 v0.22.5（`bf0203a794a07aac3ff764972ab9087baa4e4f4e`），Python 3.14.9，沿用同一个 Magpie 接入。安装在 `~/.hermes/hermes-agent`，命令位于 `~/.local/bin/hermes`；增强监听已启用。

- 官方依赖、TUI 和 Web 构建均成功。下载断连后复用按官方 SHA-256 校验的安装文件；npm 漏装的 macOS Rolldown 原生依赖按锁文件的 SHA-512 补装。非必需的 Git 完整历史刷新因网络缓慢中止，当前稳定版代码已固定，后续更新可重新刷新历史。未安装可选浏览器和桌面控制驱动。
- 实际模型执行 `sleep 12` 和验收标记成功。读取器观察到工作中，完成后 Preview 猫条显示完成。输入 4,986、输出 336、缓存读取 4,352 Token，与实际 `session_model_usage` 汇总一致。
- 默认终端界面执行 `sleep 25` 成功；猫条实际显示工作会话。任务结束且网关仍存活、`active_agents=0` 时，猫条回到空闲，完成标记保留。
- Hermes 默认智能审批会自动放行被判断为安全的临时目录删除。为便于验收，当前安装已设置 `approvals.mode: manual`，保留 `security.approval.transport: while-ai-works` 与 `transport_fallback: builtin`。在人工审批下，真实 terminal 请求经插件进入生产 Swift 服务；拒绝后客户端返回 `BLOCKED`，测试目录保留，模型未重试。
- 取消等待中的测试任务并停止其网关后，读取器不再报告工作，也没有把被取消的轮次标为完成。
- 验收时曾使用临时 socket；网关会继承启动时的环境，修改 CLI 环境不会改变已启动的网关。测试结束已停止临时网关，重新从默认环境启动。演示时使用正常的 `hermes` / `dsh tui` 即可。

仍需人工确认工作卡片按钮、实际项目、子 Agent 和不同用户配置下的体验。本机实测没有覆盖用户机器、Intel 硬件以及所有 Web/TUI 交互组合；Hermes 提问仍回原客户端回答，回复预览和主动发新消息仍未接入。

依据：[用户反馈 #1](https://github.com/xiaoyan648/while-ai-works/issues/1)、[Hermes hooks](https://hermes-agent.nousresearch.com/docs/user-guide/features/hooks/)、[Hermes plugins](https://hermes-agent.nousresearch.com/docs/user-guide/features/plugins/)，以及本机 DSH 0.2.1-rc.2 的类型声明与运行行为。

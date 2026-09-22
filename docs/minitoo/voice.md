# MiniToo 工作语音与实时闲聊

2026-09-21：已完成本地接入，并修复真机测试发现的蓝牙收音路由问题。此前 MiniToo 本地连续收音 5.0 秒（峰值 0.004），提示音播放回调完成；CoreAudio 日志确认输入、输出均使用 MiniToo 设备 UID。用户补充授权后，应用实际 Swift 客户端的 `seed-tts-2.0` 流式合成和 `volc.bigasr.auc_turbo` 识别均已通过，合成问候语再转写准确匹配。**完整硬件对话尚未验收**：本次应用内试听提示 MiniToo 扬声器未连接，需重连后核对实际播报与用户说话。

## 两种对话方式

- **工作模式**：开启 MiniToo，选择工作模式。默认全局快捷键 **Control + Option + 空格**：按一次开始收音，再按一次发送；处理或播放时再次按键停止。设置中可改为 Command + Option + 空格或 Control + Shift + 空格；冲突会提示。浮窗显示收音/处理状态，不抢当前应用焦点，不需要一直打开工作台。工作台保留按钮和文字任务。
- **闲聊模式**：选择闲聊模式，点一次「开始闲聊」，随后连续说话、由服务端判断说完并回复；点「结束闲聊」停止。接入豆包实时语音 **3.0 / Seeduplex**，不是用工作模式的 ASR、文本模型和 TTS 拼接模拟。闲聊不开放电脑工具。
- 闲聊默认复用豆包语音 Key，也可在「实时语音配置」单独保存 Key 到钥匙串 `realtime-api-key`；支持配置实时音色，默认 `zh_female_vv_jupiter_bigtts`。实时语音权限独立于工作 TTS/ASR。
- MiniToo 近距离外放容易回声，默认回复期间暂停上传收音，播放完后恢复。可以点「打断回复」；戴耳机时可开启「允许语音打断」。未接入声学回声消除，不能承诺外放全双工打断质量。
- 切换展示模式、关闭 MiniToo、关闭主设置窗口、休眠或连接异常会结束闲聊。重启/唤醒不会自动恢复监听。工作快捷键只在 MiniToo 开启且选择工作模式时注册。

## 工作语音配置入口

设置 → MiniToo → 工作模式 → 打开 Agent 工作台 → 语音与音频设备。

1. 模型配置中保存自己的火山方舟 Key 和支持工具调用的模型。
2. 语音配置中保存豆包语音控制台的 API Key，需要开通录音文件极速识别 `volc.bigasr.auc_turbo` 和所选合成资源。新控制台使用 `X-Api-Key`；本版不支持旧版 AppID + Access Token 组合。
3. 默认合成资源为 `seed-tts-2.0`，默认音色 `zh_female_vv_uranus_bigtts`。可选择 1.0 字符版/并发版及编辑音色 ID；音色必须与资源权限匹配。
4. 选择收音和播放设备，默认自动寻找 MiniToo。也可明确选择 Mac 内置麦克风/扬声器、耳机，或跟随系统默认。本应用不修改 macOS 全局默认音频设备；指定设备断开会停止，不偷偷切换到其他设备。
5. 先用「测试麦克风」「测试扬声器」检查本地链路，再点「试听音色」检查云端合成。前两个测试不需要 Key，也不上传音频。
6. 点击「开始说话」，说完点击「结束并发送」。录音最长 30 秒，到时自动结束并发送识别。语音任务默认朗读回答；文字任务是否朗读由「朗读文字任务的回复」控制。

首次收音会请求 macOS 麦克风权限。拒绝后，在系统设置 → 隐私与安全性 → 麦克风中允许本应用，再重新开始。本地麦克风测试持续 5 秒，仅报告时长、峰值和电平，不保存或上传录音；提示音测试是 0.3 秒的轻提示音。界面显示完成只说明音频回调已结束，仍需实际听感确认。

## 数据流和同步

```
MiniToo / 所选麦克风
  → Mac 内存录音（PCM16、16 kHz、单声道，≤30 秒）
  → 豆包录音极速识别（HTTPS，一次上传 WAV，返回文字）
  → 现有火山 Agent（模型 → 本地工具 → 回答）
  → 豆包语音合成（HTTPS SSE，24 kHz PCM 分块）
  → 所选扬声器（通常是 MiniToo）
```

语音识别在结束录音后提交，本版不是边说边识别。文字模型仍使用现有非流式回答；拿到完整回答后，语音音频边生成边播放，无需等整个音频下载完。播放队列控制在约两秒加一个服务分块，回复最长 1200 字、音频最多三分钟；截断时有提示。

工作模式录音与播报分开，不在播放器工作时启动麦克风。没有唤醒词。连续对话使用上面的独立闲聊模式。

MiniToo 使用既有蓝牙连接显示聆听、思考、说话和完成动画。设备自己循环播放，只有状态变化才上传；等待中的中间状态会合并。实际画面切换取决于蓝牙上传与 ACK，并不与每个音节同步，快速结束的任务可能跳过中间动作。所有模式仍手动选择，不因语音任务自动从鱼缸/Codex 跳到工作模式。

本轮未增加摄像头权限或摄像头采集。“视频”暂按现有 MiniToo 动态角色处理，若指摄像头视觉输入，需单独明确入口、帧采样和上传方式。

## 停止和错误处理

- 「停止」取消当前请求、清空未播放音频并停止收音。已经执行的 Agent 操作不会撤销。
- 关闭工作台不影响已发出的工作任务；关闭语音设置中的测试、关闭主窗口或 Mac 休眠时，停止活跃语音任务。
- 麦克风/扬声器丢失、采样转换失败、播放超时、静音、识别失败和合成服务错误都会显示明确状态。
- 识别失败不会调用 Agent。语音合成失败保留已完成的文字回答，提示语音失败，不假装已播报。
- 未收到服务端成功结束标记的音频流按异常断流处理，即使已经播放过部分声音。

## 密钥和音频保存

语音 Key 与模型 Key 在同一个应用 Keychain service 下使用不同 account：`speech-api-key` / `api-key`。留空保存会保留原 Key；移除语音 Key 不删除模型 Key。密钥不会写入偏好设置、源代码、日志或安装包，也不通过 iCloud 同步。

原始录音和合成音频只保存在内存。取消或结束录音后不创建音频文件；识别文字和回答沿用工作台内存对话。正常语音任务会将录音发送给豆包语音、将识别文本和工具结果发送给方舟、将回答文本发送给豆包语音合成。测试音频设备不进行云端请求。

## 代码与验证

- `Sources/WhileCore/VolcanoSpeech.swift`：WAV、ASR 请求/响应、SSE 分块、结束状态和脱敏错误。
- `Sources/WhileAIWorks/MiniTooVoiceAudio.swift`：CoreAudio 设备选择、指定设备 UID 的 AVCaptureSession 收音、AVAudioEngine 播放、采样转换、内存限制及路由检查。
- `Sources/WhileAIWorks/MiniTooVoice.swift`：权限、收音、识别、Agent、合成和取消状态。
- `MiniTooVoiceSettingsView.swift` / `MiniTooAgentView.swift`：配置、设备测试和说话入口。
- `bash scripts/check-voice.sh`：离线测试，不录音、不请求云端；包含真实 SwiftUI 组件的离屏布局渲染。
- `bash scripts/check-agent.sh`：原有工具循环和取消回归。
- `bash scripts/check-minitoo.sh`：动画、蓝牙协议容器和 Codex 展示回归。

离线验证已覆盖 48 kHz 双声道转 16 kHz 单声道、录音上限、取消后丢弃采样、WAV 格式、静音返回、错误服务码、SSE 任意字节边界拆分、不完整音频、结束标记缺失及 Key 脱敏。未用这些结果推断设备上的语音质量、延迟或回声表现。

初次语音接入时 `check-voice.sh`、`check-agent.sh`、`check-minitoo.sh`、`check.sh` 全部通过；arm64 本地构建、Info.plist 和严格签名校验通过。已检查语音设置与工作台的离屏渲染，未检出工程或可执行文件中嵌入 Ark 凭证。构建位于 `dist/While AI Works.app`，未发布新安装包。

### 真机收音修复

原 AVAudioEngine 输入在蓝牙协商期间被系统重新绑定到默认耳机的聚合设备，触发路由检查并立即停止录音。改为 AVCaptureSession 显式绑定麦克风 UID，启动/停止在独立串行队列执行，结束收音后等待设备释放才启动播放。输出通过 AUAudioUnit 的设备接口绑定，保留播放设备存活与路由检查，不修改 macOS 默认设备。

修复后重新运行 `check-voice.sh` 通过，增加了真实 CMSampleBuffer 转 PCM 和停止后丢弃回调的离线验证，arm64 构建通过。解锁后的应用真机验证已确认 MiniToo 连续收音及指定输出回调；云端试听实际返回 `45000010`，未生成回复音频。未读取、导出或覆盖用户已保存的密钥。

实测待完成：用户说话 → ASR 正确转写 → Agent 真正执行/回答 → 云端音频在 MiniToo 扬声器播出；同时核对角色状态、音频设备断开处理和实际声音质量。需先排除当前云端合成服务错误。

### 临时 Key 的接口对照（2026-09-21）

用户另外提供临时语音 Key 后，仅在调试进程内存中使用，对比相同的简短问候：

- `POST /api/v3/tts/create`，`model=seed-audio-1.0`：HTTP 200、服务码 `20000000`，收到 63,789 字节 MP3，服务报告时长 3.9 秒，本次请求耗时 12.79 秒。
- 应用当前的 `POST /api/v3/tts/unidirectional/sse`，`X-Api-Resource-Id=seed-tts-2.0`、`speaker=zh_female_vv_uranus_bigtts`：HTTP 200，但 SSE 事件码 `45000030`，消息 `[resource_id=volc.seedtts.default] requested resource not granted`，无音频。这是该 Key 的资源授权拦截，不能用 Seed Audio 请求成功推断流式 TTS 已授权。
- 应用的极速识别接口 `/api/v3/auc/bigmodel/recognize/flash`，资源 `volc.bigasr.auc_turbo`：HTTP 403、服务码 `45000030`。探针仅发送一秒合成静音 WAV，用来检查权限，不代表人声识别验收。

以上是新临时 Key 的结果，与前一次应用内保存 Key 返回的 `45000010` 分开记录。单次 Seed Audio 耗时不作为模型性能基准。未把临时 Key 保存到工程或覆盖应用钥匙串。

### 补充授权后的复测（2026-09-21）

直接编译调用当前 `VolcanoSpeechClient` 和 `MiniTooCaptureBuffer`，沿用同一临时 Key（只通过调试进程标准输入传入）：

- 流式 TTS 2.0 完整成功：114,428 字节 PCM，音频长 2.38 秒，首段 0.72 秒、收完 0.92 秒，客户端验证了服务端结束标记。
- 将这段 24 kHz 音频经应用转换器转为 16 kHz WAV，再调用极速识别：0.58 秒返回“你好，我是你的工作助手。”，与输入文字一致。
- 这是云端合成→采样转换→云端识别的验证，不含真人麦克风、Agent 工具执行或扬声器听感；耗时仅代表本次单次请求。
- 应用内另行尝试试听时，原设置为 1.0 并发版、`zh_female_shuangkuaisisi_moon_bigtts`，在开始请求前因 MiniToo 扬声器未连接而停止。单独用同一临时 Key 调用该 1.0 配置仍返回 `45000030`。已在设置中保存验证成功的 2.0 / `zh_female_vv_uranus_bigtts`，Key 输入留空，保留原存储。待重连后验证应用保存 Key 的实际播报。

## 官方接口依据

- [录音文件极速识别 API](https://docs.volcengine.com/docs/DoubaoVoice/LargemodelrecordingfileLiterecognitionAPI?lang=zh)
- [HTTP Chunked / SSE 单向流式语音合成 V3](https://docs.volcengine.com/docs/DoubaoVoice/HTTPChunkedSSEUnidirectionalStreaming-V3?lang=zh)

## 实时连接、音频格式与性能边界

实时入口为 `wss://openspeech.bytedance.com/api/v3/duplex/realtime/dialogue`，使用 `X-Api-Key`，JSON `session.create` 的 `session.model` 为 `1.2.6.1`。建立连接超时 15 秒；主动结束先发送 `session.close`，最多等待 2 秒确认后释放连接。

麦克风音频经转换后以 16 kHz / PCM16 单声道、每帧 640 字节、20 ms 节奏发送。待上传缓冲最多 2 秒；发送明显落后或缓冲溢出即停止，不补发大批过时音频。返回事件队列最多 128 项，播放队列最多 15 秒。文本显示有长度限制，录音和回复不保存到磁盘。

**官方新文档与实测存在格式差异**：`session.audio.output.format.type=pcm` 实测返回 24 kHz Float32 小端 PCM，符合旧版实时接口的 `tts.audio_config.format=pcm` 行为。客户端严格验证有限浮点采样，转成 PCM16 后送入既有播放器，避免把浮点字节误当整数播放。新版 ASR 的 `delta` 实测是累计修订文本，显示时替换假设，不重复拼接；最终文本兼容 `text` 和 `transcript` 字段。

2026-09-21 云端实测：实时会话成功创建，按 20 ms 节奏输入「你好，请用一句话介绍你自己。」音频，返回识别「你好，请一句话介绍你自己。」，模型回答「我是MiniToo，能陪你轻松闲聊、解答问题的桌面聊天伙伴。」及对应音频；收到 `response.done` 后发送关闭，收到 `session.closed`。这是实际云端音频问答，尚不能替代 MiniToo 真机收音和播放验收。

官方依据：[3.0 全双工协议](https://docs.volcengine.com/docs/DoubaoVoice/endtoend-realtime-voice-full-duplex-version?lang=zh)、[接入必读](https://docs.volcengine.com/docs/DoubaoVoice/access-mustread?lang=zh)、[旧版实时音频格式说明](https://docs.volcengine.com/docs/DoubaoVoice/End-to-endreal-timespeechlargemodelAPIaccessdocument?lang=zh)。


### 本地交互验证

2026-09-21 已在原生应用验证：工作模式快捷键开始 MiniToo 收音，再次按键结束并进入识别，Agent 收到识别文本并回答；停止按钮终止后续处理/播报。闲聊模式成功创建实时连接，在 MiniToo 麦克风上连续收音、显示实时转写，结束闲聊后关闭麦克风。本轮实际保存的播放设备为 vivo 耳机，保留用户选择；未把这项测试写成 MiniToo 扬声器听感验收。MiniToo 屏幕传输此时提示设备未回应，显示链路需独立重试，音频连接成功不代表动画已收到。

客户端 Float32→PCM16 修正后，实际收到 171,842 字节可供播放器使用的 PCM16，收到 `response.done` 和 `session.closed`；未通过纯回调推断用户实际听感。闲聊结束状态下不会自动重新连线或收音。

最终本地验证：`check-voice.sh`（含实时协议、连续收音缓冲和界面渲染）、`check-agent.sh`、`check-minitoo.sh` 均通过；arm64 构建和 `codesign --verify --deep --strict` 通过。应用已重新打开，本轮未发布安装包。测试结束后未继续监听。

## 2026-09-21 实时闲聊启动与卡顿修复

- 当日 18:13:06 的应用日志显示：播放引擎启动约 24 ms 后发生 `iounit configuration changed > stopping the engine`，随后被旧逻辑当成设备断开而结束会话。
- 同次会话的聆听动画上传为 48,906 字节、约 12.2 秒，结束后的待机动画为 42,007 字节、约 3.7 秒。闲聊现改为固定单帧，聊天时禁止重传，工作模式保留动作动画。
- 收音、播放绑定本次选定的物理设备 UID。启动后异步等待播放稳定 0.5 秒，再启动 20 ms 收音发送循环；准备阶段丢弃收音，避免积压。相同设备仍连接而空闲引擎停止时允许重建输出连接并重启，10 秒内最多三次。实际断线、换设备、已有回复播放中断仍报告错误。
- 音量指示降至每秒更新十次；音频帧仍按每秒五十帧发送。
- 无设备回归：`bash scripts/check-voice.sh`、`bash scripts/check-minitoo.sh`。可选播放硬件回归：`.build/native/MiniTooVoiceAudioChecks --playback-device`，使用 MiniToo 播放引擎与静音数据验证恢复、重试上限和中断保护，不打开麦克风或调用云端。
- 这些检查不等于双向蓝牙通话验收；仍需在应用内验证连续收音、播报、打断和退出。

本轮 `check-voice.sh`、`check-minitoo.sh` 通过；额外在已连接的 MiniToo 上运行 `--playback-device` 通过，验证三次相同设备空闲播放引擎恢复、第四次限流、队列中已有回复时报告中断以及显式停止后不重启。此测试仅使用静音数据，没有打开麦克风或请求云端。完整应用双向通话复测受 macOS 锁屏阻挡。

引擎配置变更行为参考 [Apple AVAudioEngineConfigurationChange](https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/avaudioengineconfigurationchange)。

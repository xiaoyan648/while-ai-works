# AI 干活时我们干什么

**While AI Works** · AI 在干活，你在桌面上歇一会儿。

原生 macOS 桌面解压应用：擦污渍、捏气泡、敲木鱼、钓鱼和水下观赏。可以随时玩，也可以跟随 Codex、Qoder、WorkBuddy 的工作状态。鱼获、图鉴和各玩法累计记录保存在本机。

![水下观赏](images/aquarium.png)

## 下载

[下载 0.14.0 测试版](https://github.com/xiaoyan648/while-ai-works/releases/tag/v0.14.0-beta.1)

- **Apple Silicon（M 系列） · macOS 14 或更新版本**
- 下载 `While-AI-Works-0.14.0-macOS-arm64.zip`，解压后将 `While AI Works.app` 拖入「应用程序」。
- 此测试版使用 ad-hoc 签名，**尚未通过 Apple Developer ID 签名和公证**。macOS 可能拦截首次打开；确认下载来源后可按 [Apple 官方说明](https://support.apple.com/zh-cn/102445)在「系统设置 → 隐私与安全性」中处理。无需关闭系统安全保护。
- Release 同时提供 SHA-256 校验文件。Intel 和 Windows 暂未发布安装包。

## 使用

打开应用，点击「开始玩」，选择一种玩法。按 **⌘⇧空格** 开始玩或收起效果；关闭设置窗口后仍可从菜单栏操作。

- 擦污渍：拖动帕子擦净桌面边缘的污渍。
- 捏气泡：点击或划过气泡膜。
- 敲木鱼：每次敲击 +1；AI 工作时每 5 秒 −1。
- 钓鱼：按住蓄力、松开抛竿；咬钩后提竿，按下/松开控制绿色浮条追鱼，收集图鉴并放入水下观赏。

多屏可选效果所在屏幕。音量、自动轮换和全局快捷键可以在设置中调整。

## 跟随 AI

「什么时候」可选随时开启、Codex、Qoder 或 WorkBuddy。Qoder / WorkBuddy 需点击「安装监听」，再重启对应客户端；如有 Hooks 审核提示，需在客户端启用。可通过「移除」撤销本应用的 Hooks。

[安装、隐私和监听边界](INTEGRATIONS.md)

普通玩法不需要屏幕录制、辅助功能或麦克风权限。不读取桌面画面，没有账号系统或遥测服务。Codex 使用本机任务日志；Qoder / WorkBuddy 通过 Hooks 接收事件，只持久化必要状态。应用不会上传对话或代码。

## 测试版与反馈

本仓库用于分发安装包、发布说明和接收问题反馈，暂不公开源码。发现问题请 [提交 Issue](https://github.com/xiaoyan648/while-ai-works/issues)，附上 macOS 版本、芯片和复现步骤；请勿上传含对话、代码或凭证的完整客户端日志。

# 0.14.0 beta 1

首个 GitHub 公开测试版，支持 Apple Silicon、macOS 14+。

- 四种桌面玩法：擦污渍、捏气泡、敲木鱼、钓鱼。
- 鱼图鉴、累计记录、水下观赏和多屏选择。
- 保留 Codex 本地工作日志监听，新增 Qoder / WorkBuddy 官方 Hooks 接入。
- 设置内安装/移除监听，保留其他 Hooks，备份原有配置。
- 只保存必要工作状态，不上传代码和对话。

## 安装

下载 ZIP，解压后将应用拖入「应用程序」。此包仅做 ad-hoc 签名，未使用 Developer ID 签名或 Apple 公证；首次打开可能被 Gatekeeper 拦截。请参照仓库 README 的 Apple 官方说明。

SHA256SUMS.txt 可核对下载完整性。

## 验证与限制

监听协议模拟与本地集成检查覆盖两个客户端的开始/结束、多会话、来源隔离、超时与 Codex 回归。尚未在 Qoder、WorkBuddy 中分别真实运行任务做端到端验收；需要支持 Hooks 的版本，并完成客户端要求的配置审核。

一次跟随一个客户端。20 分钟无新事件时停止识别工作；长时间纯思考或客户端不发结束事件时可能不准确。Qoder CN / 通义版、CodeBuddy CLI、Intel 与 Windows 不在本次安装包支持范围。

# 开发说明

先按 [README](README.md#源码与构建) 构建，再运行下方检查。提交改动时请描述可复现的问题、改动行为和实际验证范围；不要提交客户端私人日志、对话、凭据或生成服务临时下载地址。

## 构建依赖

需要 macOS 14+、Apple Command Line Tools（Swift 6.1+）和 Python 3。第三方依赖包括 [Rive](https://github.com/rive-app/rive-ios) 运行时（MIT）、[Sparkle 2.10.0](https://github.com/sparkle-project/Sparkle) 更新框架（MIT 及其第三方声明）和固定版本的 [Agent HUD Core](Vendor/AgentHUDOpen/README.md)（Apache-2.0）。Rive 与 Sparkle 首次构建时下载官方发布包并校验 SHA-256；Agent HUD Core 源码随仓库提供，用于 Codex / Claude 用量及会话接入。

依赖就绪后可离线构建，不需要生成服务 API Key 或 Blender。构建脚本生成完整应用和 Hooks 辅助程序，并使用本地 ad-hoc 签名；构建结果没有 Developer ID 签名或公证。更新发布流程与派生项目配置见 [应用更新](docs/updates.md)。

## 运行检查

```sh
# 核心玩法、音效、交互、鱼模型和图鉴检查
bash scripts/check.sh
# Hooks 协议、配置安装/移除与监听集成检查
bash scripts/check-hooks.sh
# 检查已构建的真实 Hooks 辅助程序
python3 Tests/HookExecutableChecks.py
# 生成工具的离线请求测试，不调用生成服务
python3 Tests/test_volcengine_asset.py
# 菜单栏面板、设置和收藏窗口的离屏渲染（浅色 / 深色），输出到 .build/ui-review
bash scripts/check-ui.sh
```

请按顺序执行。专项检查与运行环境限制见下方「检查边界」。

## 目录

- `Sources/WhileCore`：玩法、钓鱼、收藏、工作状态和 Hooks 协议。
- `Sources/WhileAIWorks`：SwiftUI/AppKit 界面、桌面图层、SceneKit 鱼缸和资源。
- `Tests`：核心检查、原生渲染/交互和 Hooks 隔离检查。
- `scripts/build.sh`：构建应用、辅助程序、图标并签名。
- `scripts/toolchain.sh`：工具链和架构配置；兼容文件仅写入 `.build`。
- `scripts/art`：美术加工与生成工具源码，不参与普通应用构建。
- `assets`：应用 Info.plist 和图标。
- `design/mascot`：菜单栏小猫的 Rive 源文件与生成脚本，见 [小猫说明](design/mascot/README.md)。

`Package.swift` 提供 SwiftPM 入口：标准工具链可执行 `swift build` 和 `swift run CoreChecks`。完整 `.app`、Hooks 辅助程序、图标和资源处理以 `bash scripts/build.sh` 为准。

## Intel 与打包

```sh
TARGET_ARCH=x86_64 bash scripts/build.sh
bash scripts/package-release.sh "dist/x86_64/While AI Works.app"
# 本机架构 DMG 与 ZIP 安装包
bash scripts/package-release.sh
```

Apple Silicon 上交叉编译的 Intel 应用位于 `dist/x86_64`。运行 x86_64 程序需要 Rosetta 或 Intel Mac；交叉编译通过不代表 Intel 真机验收。`package-release.sh` 同时生成 DMG、ZIP 与 SHA256SUMS.txt，校验两个辅助程序架构，并挂载 DMG 检查 Applications 快捷入口、应用逐文件一致性及签名。

应用内更新采用 Sparkle。两种架构打包后运行 `bash scripts/generate-appcast.sh`，将签名清单与安装包一同上传 Release；具体流程、钥匙串签名账户和测试边界见 [应用更新](docs/updates.md)。

鱼缸模型与纹理按需下载，不再放入主应用。资源包构建、独立版本、缓存和发布顺序见 [鱼缸资源](docs/aquarium-resources.md)；应先发布资源包，再发布引用它的应用。

## 检查边界

`check.sh` 和 `check-hooks.sh` 应顺序执行，它们共用 `.build/native`。原生渲染检查需要可用的 macOS 图形环境。测试使用隔离偏好域和临时 Hooks 目录；自动化协议测试不能代替每个 AI 客户端版本的真实任务验收。

桌面小猫相关改动在构建后运行 `bash scripts/check-desktop-pet.sh`，检查独立开关、状态展示、位置恢复与不抢焦点的窗口。`check-hooks.sh` 同时覆盖关闭游戏后的小猫独立监听，`check-ui.sh` 输出浅/深色及精简模式的界面图。

专项脚本覆盖鱼缸运动、碰撞、显示屏与水下观赏。`check-release-resources.sh` 需要先编译参数指定的检查程序，再让它读取实际应用包的资源。例如：

```sh
bash scripts/check.sh
bash scripts/check-release-resources.sh NativeFishingGuideChecks
```

精简应用的上述渲染检查同时读取 `dist/resource-packs` 中与应用清单匹配的独立鱼缸 ZIP，校验后仅在测试 Bundle 中挂载素材；可通过 `AQUARIUM_PACK_ARCHIVE` 指定其他已下载的 ZIP。首次未下载的提示界面由 `bash scripts/check-aquarium-resource-ui.sh` 检查，下载及缓存行为由 `bash scripts/check-aquarium-resources.sh` 检查。

## 美术工具

构建所需成品资源已经包含在仓库内。原始 Blender 工程、生成服务响应、任务清单、临时下载链接和本地验收产物未发布。`scripts/art` 中部分加工工具依赖这些外部输入，不能将其视为克隆后可直接重建所有美术的流水线。

按具体工具需要自行准备 Blender、Python 依赖和输入文件。生成服务凭据通过环境变量、隐藏输入或显式指定的本地文件读取；实际提交生成任务可能消耗服务额度。普通构建和测试不会提交生成任务。

代码贡献按 [MIT License](LICENSE) 提供。新增素材须写明来源及许可，不要默认沿用代码许可证。现有素材说明见 [ASSETS.md](ASSETS.md)。

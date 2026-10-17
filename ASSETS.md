# 资源来源与许可范围

根目录 `LICENSE` 的 MIT 授权适用于本项目代码、脚本和文字文档。以下非代码素材不纳入该 MIT 授权：`Sources/WhileAIWorks/Resources/` 中的图片、纹理与网格数据，`assets/AppIcon.png`，以及 `images/` 中的截图。随仓库提供这些资源是为了保留应用的构建与展示所需文件；本次代码开源不对这些素材另行授予独立再授权或商用许可。

## 来源记录

| 资源 | 制作来源 |
| --- | --- |
| 鱼图鉴插画、背景、前景和应用图标 | 项目制作过程中的 AI 图像生成与加工 |
| 河豚模型及部分历史造景 | Microsoft TRELLIS.2 生成，经过 Blender 加工及原生格式导出 |
| 鲫鱼模型 | Tencent Hunyuan 3D 生成，经过减面、纹理缩放与骨骼动画加工 |
| 其余 12 种常规鱼模型 | 经 Volcengine Ark 调用 Hyper3D 生成，再经 Blender 加工 |
| 巨物鱼网格及初版简化模型 | 项目 Python/Blender 脚本制作，巨物纹理使用生成插画 |
| 菜单栏小猫（墨 / 雪）动画 | 项目原创，`design/mascot/build_scene.py` 生成 Rive 场景，由 Rive CLI 编译为 `mascot.riv` |
| 灵猫应用图标（2026-10-17） | 内置 `image_gen` 参考项目原创墨猫静帧生成，提示词见 [图标制作记录](design/mascot/app-icon-prompt.md)，原生脚本生成圆角与多尺寸 ICNS |
| 产品截图 | While AI Works 应用截图 |

上述记录描述制作来源，不表示生成服务或模型供应商为本项目背书。仓库未包含每项生成服务的完整输出授权凭据，不将这些素材统一声明为 MIT。若要将素材用于其他项目，请自行核实相应授权或替换素材。

美术加工工具的 Python 源码属于 MIT 授权范围。运行应用与普通构建无需调用任何上述服务。小猫动画由 [Rive](https://github.com/rive-app/rive-ios) 运行时播放，该运行时采用 MIT 许可，构建时从官方发布页下载，随应用包分发；版权与许可文本保存在 `Sources/WhileAIWorks/Resources/Licenses/RiveRuntime-MIT.txt`，并随安装包保留。

## AI 客户端标志

`Resources/AgentMarks/` 保留 Agent HUD Open 中的 ChatGPT、Claude、Qoder、WorkBuddy 原始 PNG，固定于 `faa3a06fcf06510855ada332ea454f1f6df30ab4`。来源及上游 Apache-2.0 许可随应用保存在 `Resources/Licenses/AgentMarks-SOURCE.txt` 与 `AgentHUDOpen-APACHE-2.0.txt`；上游第三方声明亦保留。标志用于识别对应客户端，不表示商标权转让或供应商背书。猫条的耳尾与贴边窗口轮廓是本项目原生界面几何。

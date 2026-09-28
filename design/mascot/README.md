# 菜单栏与桌面小猫

菜单栏面板、设置和桌面宠物共用一个 Rive 动画资源（`mascot.riv`），由 [Rive CLI](https://rive.app) 从本目录的源文件编译。三个展示位置各有独立的运行时实例，关闭面板不会暂停桌面小猫。应用通过 Rive 运行时播放，并用数据绑定驱动它的状态。

桌面小猫由 `DesktopPetController` 管理，开关独立于小游戏；在工作时专注观看，无工作时打盹，开启游戏时跟随玩法，点击可摸摸。拖动与点击由原生窗口区分，拖动不会误触摸摸。状态卡显示每个工具的工作会话、待连接或未关注状态，窗口不获取键盘焦点，拖动位置按屏幕及相对位置保存。

造型是一只纯色的「灵猫」：墨（黑）或雪（白）一整块剪影，没有嘴、鼻子和条纹，表情全靠眼睛；身边有一颗光球陪它玩，周围飘着萤光。光晕用 Rive 的羽化描边（Feather）和径向渐变实现：亮色的光只在深色背景上显现，暗色的影子只在浅色背景上显现，所以同一个文件在浅色和深色面板上都成立，不需要外观参数。每个身体部位都有一个只画光晕的「Glow」副本，通过 DrawRules 统一排在所有毛色之后，光只出现在整只猫的外轮廓上，头和身体之间没有接缝。

| 文件 | 作用 |
| --- | --- |
| `build_scene.py` | 唯一的源头：造型、配色、动画、状态机和数据模型都在这里，坐标为 240 × 240 画板（y 向下） |
| `scene.rml` | 由脚本生成的 Rive 场景，不要手改 |
| `rive.yaml` | Rive 项目配置 |
| `preview.sh` | 渲染所有状态 × 两种毛色 × 浅色 / 深色的对照图，输出 `build/contact-sheet.png` |
| `stills.sh` | 渲染透明底静帧，供离屏界面渲染和文档使用，输出 `build/stills/` |

## 应用可以控制的属性

数据模型名为 `Cat`：

| 属性 | 类型 | 说明 |
| --- | --- | --- |
| `mood` | 枚举 `idle` / `sleep` / `watch` / `play` / `proud` / `curious` / `effort` / `focus` | 等你开始，目光追着光球，偶尔伸爪拍一下 / AI 没开工时打盹，光球落地变暗 / 钓鱼时竖瞳、耳朵朝前，偶尔瞳孔一放大 / 其他玩法时扑光球；扩展状态分别为收获开心、杂物好奇、搏鱼用力、敲木鱼专注 |
| `coat` | 枚举 `ink` / `snow` | 墨（黑猫，发光的青绿色眼睛）或雪（白猫，深色眼睛），切换时颜色渐变 |
| `lookX`、`lookY` | 数字 −1…1 | 眼睛和脸朝向，应用用鼠标位置驱动；内置缓动 |
| `celebrate` | 触发器 | 蹲一下跳起来，眼睛变星星，炸开一圈光点，落地后头顶跃出一条光做的小鱼，光球绕着转一圈；菜单栏通用庆祝反馈；桌面钓获使用 `proud` 与原生固定卡通鱼叠层 |
| `pet` | 触发器 | 眼睛眯成 ^^、脸红、歪头往你这边靠、耳朵向后，冒一颗爱心；点击小猫时由动画内部触发 |

对应关系写在 `AppState.mascotMood`、`AppState.companionMood` 和 `MascotController` 里。

## 修改流程

```sh
export PATH="$HOME/.rive/bin:$PATH"
python3 design/mascot/build_scene.py            # 重新生成 scene.rml
rive design/mascot --verify                     # 编译检查
rive inspect design/mascot --summary            # 数据绑定、状态机接线检查（problems 应为空）
design/mascot/preview.sh                        # 看所有状态
rive design/mascot --once                       # 生成 build/mascot.riv
cp design/mascot/build/mascot.riv Sources/WhileAIWorks/Resources/Rive/mascot.riv
```

实时预览：`rive design/mascot` 会打开一个窗口，保存后自动刷新。也可以直接指定状态截图，例如 `rive design/mascot --screenshot=a.png --data=mood=sleep --data=coat=ink --advance=120`。

## 交给设计师

`scene.rml` 可以导出为 Rive 编辑器文件：先 `rive login`，再 `rive design/mascot --once --rev=design/mascot/build/mascot.rev`，用 Rive 桌面端打开即可继续调整；也可以用 `rive push` 上传到自己的 Rive 账号。

在编辑器里改过以后，编辑器文件就成了新的源头：用 `rive create <目录> --from-rev=mascot.rev` 转回 RML，不再使用 `build_scene.py`，并保持上面的属性名不变，应用才能继续驱动它。

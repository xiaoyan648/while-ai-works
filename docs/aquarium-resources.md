# 按需下载鱼缸资源

应用默认携带小猫、Agent 状态、钓鱼和鱼图鉴资源。首次进入「收藏 → 水下观赏」时展示下载提示，点击「下载并开启鱼缸」才联网下载。提示显示下载体积和安装后体积，支持进度、取消和失败重试。下载后可离线观赏；鱼获、收藏和入住名单仍保存在原有偏好中。

## 资源与安装

- `Resources/AquariumPack.json` 随应用签名，固定资源版本、HTTPS 下载地址、ZIP 的长度和 SHA-256，以及全部文件的大小和 SHA-256。
- 模型和纹理保留原有质量，打成独立的数据包；不含可执行文件。Apple Silicon 与 Intel 共用同一个包。
- 安装目录为 `~/Library/Application Support/WhileAIWorks/ResourcePacks/aquarium-v<版本>-<SHA256>/AquariumAssets`。应用普通升级复用同版本缓存。
- 下载到临时文件，完整 ZIP 校验通过后在缓存目录内解压。文件清单、大小和逐文件 SHA-256 全部通过后才原子安装并写入校验凭据。取消或失败会清理本次临时文件，不改变已有有效版本。
- 打开鱼缸时检查校验凭据及文件存在、类型和大小；缺失的缓存会提示重新下载。卸载应用不会自动删除这个缓存目录。
- 开发用原生资源检查仍可直接读取测试 Bundle 中的 `AquariumAssets`；正式 `build.sh` 和 SwiftPM 应用都排除该目录。

## 构建与发布

普通构建运行 `python3 scripts/package-aquarium-assets.py --check`，检查源码资源清单与固定版本一致，且会删除旧增量构建遗留的内置鱼缸目录。

```sh
# 根据现有清单重建独立 ZIP，不改变资源版本。
python3 scripts/package-aquarium-assets.py

# 美术资源改变后，增加独立资源版本并更新应用中的清单。
python3 scripts/package-aquarium-assets.py --version 2 --update-manifest

# 本地 HTTPS 下载测试，以及真实资源包的隔离安装检查。
bash scripts/check-aquarium-resources.sh \
  Sources/WhileAIWorks/Resources/AquariumPack.json \
  dist/resource-packs/aquarium-v1/While-AI-Works-Aquarium-v1.zip
```

输出位于 `dist/resource-packs/aquarium-v<版本>/`，包含 ZIP、清单和 `SHA256SUMS.txt`。已使用的版本不可替换内容，应递增版本；应用版本无需与资源版本同步。

资源包应先上传到清单指定的 GitHub Release，再发布引用它的应用版本。v1 的标签为 `aquarium-assets-v1`，附件名为 `While-AI-Works-Aquarium-v1.zip`。发布时必须设置 **`--latest=false`**，避免资源发布成为仓库的 Latest Release，影响已有 Sparkle `/releases/latest/download/appcast-<架构>.xml` 更新地址。资源包构建脚本不会上传、创建远程标签或发布 Release。

正式发布前，从公开下载地址重新下载 ZIP，确认大小和 SHA-256 与应用清单一致，并在没有缓存的 Mac 上完成首次开启与离线重开验收。下载检查采用本地 HTTPS 服务模拟网络；本地通过不代表公网资源已发布。

## 本地检查覆盖

`check-aquarium-resources.sh` 使用临时目录和本地 HTTPS 服务，不改用户的鱼获和真实资源缓存。覆盖打开时不自动下载、进度、取消后重试、HTTP 错误、截断响应、校验失败、完整安装、缓存复用、缺失文件修复及版本隔离。带参数时另行校验安装完整的发行资源 ZIP。

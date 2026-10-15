# 应用更新

从 0.17.1 起，设置「关于」、应用菜单及菜单栏右键菜单提供「检查更新」。自动检查默认开启，可在设置中关闭；默认由用户确认下载安装。Sparkle 负责更新周期和偏好存储，不额外上传系统信息。

## 分发与信任

使用固定版本 Sparkle 2.10.0。框架和发行工具由构建脚本从官方 Release 下载，先校验 SHA-256，再解压；包内保留完整许可文本。

两个架构分别使用 `releases/latest/download/appcast-arm64.xml` 和 `appcast-x86_64.xml`。清单作为正式 Release 附件与 ZIP、DMG 一同发布；草稿不会成为更新源，避免先公布新版本、后上传安装包的空档。Sparkle 使用 ZIP 更新应用，DMG 供首次安装或手动升级。

清单及更新包均使用 Ed25519 签名；`SURequireSignedFeed` 和 `SUVerifyUpdateBeforeExtraction` 开启。公钥在 `assets/Info.plist`，私钥只保存在维护者本机钥匙串，账户为 `local.whileaiworks.mac`。签名工具不导出私钥，不把私钥放进仓库、应用包或日志。维护者需要备份自己的登录钥匙串；更换密钥须按 Sparkle 官方迁移流程处理，不能随意生成新密钥替换公钥。

Sparkle 的更新签名与 Apple Developer ID / 公证是不同机制。当前应用仍为 ad-hoc 签名，首次安装提示不由 Sparkle 解决。

## 发布

1. 递增 `CFBundleVersion` 和展示版本，写好 `docs/releases/<版本>.md`。
2. 构建并打包 arm64、x86_64 两种架构：`bash scripts/build.sh`、`TARGET_ARCH=x86_64 bash scripts/build.sh`、两次 `package-release.sh`。
3. 运行 `bash scripts/generate-appcast.sh`。官方工具按包内版本、最低系统要求和架构生成清单，嵌入同版本发布说明并签名。输出到 `updates/` 便于代码审查，同时复制到版本发行目录；SHA256SUMS.txt 覆盖两种安装格式与两份清单。
4. 运行 `bash scripts/check-updates.sh` 和相关回归检查，核对包内 Feed URL、公钥、Framework 和许可。
5. 提交、合并、推送代码与标签，将四个安装包、两份签名 XML 和 SHA256SUMS.txt 上传草稿 Release。全部附件的服务端文件大小和 SHA-256 与本地一致后，再公开并设为 latest。
6. 不带登录凭据下载正式清单与校验文件，再验证签名和下载地址。已发布附件不直接替换；修复时发布递增版本。

新环境首次准备维护者密钥可使用发行工具 `generate_keys --account local.whileaiworks.mac`；已有密钥会被复用。派生项目应使用自己的 Bundle ID、更新源和签名密钥，避免订阅本项目更新而被官方版本覆盖。

## 检查范围

`Tests/SparkleUpdateChecks.py` 使用官方生成和签名工具、回环 HTTP 服务和 `.build` 中的临时应用副本；HTTP 例外只存在于临时测试包，正式包保持 HTTPS。真实 Sparkle 执行检查、下载、验签、解压、安装并请求重启，随后核对安装结果与发行包逐文件一致。覆盖取消、已是最新版、篡改清单、损坏安装包和正常升级，不替换 `/Applications` 中已安装的应用。

此脚本需要维护者签名钥匙串和已经打包的本机架构应用。测试前先退出其他正在运行的 While AI Works，避免单实例保护让更新后的临时副本立即退出；脚本只结束自己重新启动的临时进程。普通代码构建不需要私钥。Intel 的运行检查可在 Rosetta 下执行，仍不等于 Intel 硬件验收。

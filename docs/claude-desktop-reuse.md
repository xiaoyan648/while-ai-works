# Claude 桌面登录复用

本次行为：优先使用桌面端当前账户和组织的已有登录；不可用时使用 Claude Code。启动、开启关注或调整监听只做静默检查。设置与猫条用量页提供手动复用/登录入口，后台绝不启动浏览器登录或钥匙串授权。

## 实现依据

只读检查本机 Claude 的 `app.asar`：`.vite/build/index.chunk-OfNecTbZ.js` 中的 `readPlanUsage` 使用已保存的 Code OAuth bearer 请求 `https://api.anthropic.com/api/oauth/usage`，附带 `anthropic-beta: oauth-2025-04-20`。主 bundle 中的 OAuth 实现使用 `config.json` 的 `oauth:tokenCache` / `oauth:tokenCacheV2`，按账户、client、组织、主机、scope 组合键保存加密缓存；`/api/oauth/profile` 用于核对账号和组织。

REA 静态分析 Evidence：`ev_ce0b70aa628adae220d39778795580968780eb3b564725dfa621f8b22f3f2553`，ASAR SHA-256 `b2dfbbb40325d978dcb7561ad12a6f9bc199f8f46b7d3d2897af74ce8965d68a`。仅选择额度模块进行静态图分析，其他依赖通过本地只读文本检查；不宣称覆盖整个程序。包内部分 unpacked native 文件和 ASAR 声明的摘要不一致，工具标记为不可信；未执行这些文件。真实额度查询另行完成了下述实机验证。

Safe Storage 格式参考 Chromium [macOS OSCrypt 源码](https://chromium.googlesource.com/chromium/src/+/93d0dcd55046ac06154f4d642c26d7697c4b0304/components/os_crypt/sync/os_crypt_mac.mm)。实现使用系统 Security、CommonCrypto、CryptoKit 和 SQLite，没有新增外部依赖。

## 读取边界

- 不读取浏览器资料，不复制登录到猫条配置，不写回 Claude 配置，不刷新或轮换 Claude 的 refresh token。
- 凭据仅在独立 helper 内存中使用，只发往固定的 Anthropic HTTPS 主机；拒绝 HTTP 重定向。父进程只接收经过筛选的额度、账户/组织标识和计划。
- 读取 Cookie 的当前组织，检查登录 Cookie 存在；远端 profile 与缓存账号必须一致，查询前后本地账号、组织和 token 必须一致。新版缓存的撤销项优先于旧版。
- 主进程对后台 helper 设置 20 秒期限，手动授权为 120 秒；HTTP 请求限制耗时和响应大小。连接检查和采集共用一分钟缓存及进行中的请求；手动重新检测跳过旧缓存。
- 静默 Keychain 查询同时设置旧式 `SecKeychainSetUserInteractionAllowed(false)` 和禁止授权 UI 的参数。单独使用后者在本机 legacy ACL 读取中会等待，因此必须在隔离进程内同时关闭交互。
- 钥匙串拒绝读取时显示“复用 Claude 桌面登录”，而不是“已退出登录”。系统授权仅由该按钮触发；没有可复用登录时才提供官方 CLI 登录。缓存过期提示打开 Claude 刷新，不自动开启登录。
- 这是对当前桌面客户端实现的兼容，不是公开稳定 API。后续格式变化会停止桌面读取，尝试 CLI，并显示可重试的错误，不生成估算额度。

## 验证

- `scripts/check-claude-desktop-usage.sh --live-silent`：加密缓存/Cookie fixture、错误主机、账号/组织隔离、撤销覆盖、过期、禁止 plaintext 回退、锁定凭据、模拟 API 成功/401/503/302、查询中切换账户、敏感凭据不输出。
- `scripts/check-claude-subscription.sh`：启动和开关不会登录或请求钥匙串授权，手动复用、桌面优先、CLI 回退、不需要 CLI 也能读取桌面额度、缓存合并、实际 provider 额度输出，及原有 CLI 登录/取消/超时清理。
- `scripts/check-agent-data.sh` 与 `scripts/check-ui.sh --claude-subscription`：既有额度语义回归及设置/猫条手动入口的明暗布局。

2026-10-27 在本机完成真实验证：

- 未授权时，启动及关闭/开启 Claude 关注均静默返回 `locked`，没有登录或钥匙串弹窗。
- 用户通过设置中的“复用 Claude 桌面登录”手动完成系统授权后，独立 helper 静默返回 `available`，真实远端 profile 与 usage 校验通过；未重新登录 Claude。
- 猫条显示订阅计划和当前会话/每周剩余额度，与 Claude 桌面端的每周已用比例一致。手动刷新成功。
- 退出并重新启动同一安装包后，自动恢复真实额度，没有授权弹窗；重启以来的 Security 日志没有新的授权提示。

实机记录与截图保存在本机 `.build/claude-desktop-reuse/`，不发布账户标识或凭据。钥匙串授权取决于用户选择及应用签名；客户端或 helper 签名变化后，系统可能要求再次手动授权读取，这不等于重新登录 Claude。

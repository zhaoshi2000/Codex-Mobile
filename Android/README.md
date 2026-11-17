# AstroGate 管家 · Android

支持 **Android 10 / API 29 及以上**。通用 APK 可安装在 ARM、ARM64、x86 和 x86_64 设备，不需要 Apple 开发者账号。Android 与 iPhone 共享电脑连接协议和中转服务器。

## 使用

1. 在电脑解压并运行仓库 Release 中的 AstroGate Connect Windows 包，保持 Codex 桌面应用打开。
2. 安装 Android APK，进入 **连接 → ＋ → 扫码**，扫描电脑连接程序生成的配对二维码。也可粘贴配对链接。二维码两分钟内有效。
3. 在连接页选择电脑，自动进入第一个 **Codex** 页，选择或新建对话。电脑与手机显示同一条原会话；电脑需要持续开机、联网。
4. **服务 → 文件管理器** 管理本机文件；**服务 → ＋** 添加 SSH、SFTP、FTP 或 OpenClaw。SSH 首次连接先核对服务器指纹；SSH 类型直接打开终端。
5. **设置**填写 HTTPS AI 接口地址和 API Key，自动获取模型，选择后保存。在 SSH 页面右上角打开 AI 助手；每个拟执行的服务器命令都需确认。
6. **服务 → ZeroTier 内置网络** 填写网络 ID 并启用，在网络管理后台授权此手机节点；无需安装手机 ZeroTier App。FTP 配置可勾选内置网络。文件下载和 **主机网页服务** 可选择直连或服务器中转，详见[内置网络说明](../docs/embedded-network.md)。

跨网络需要运行现有 `Connect` 中转服务。已有 iPhone 部署可以复用，不需要为 Android 另建服务。自建部署见 [Connect 文档](../Connect/README.md)。

## 已接入功能

- 四个入口依次为 Codex、连接、服务、设置；连接管理 Codex 电脑，服务包含文件管理器和服务器；跟随系统深浅色。
- 扫码/链接配对、设备重命名、移除配对；X25519 + HKDF + AES-GCM 端到端加密及消息顺序校验。
- 项目默认折叠、最近对话每页 20 条、项目内/外新建、重命名、确认删除、从指定轮次创建分支。
- Codex 剩余额度和重置时间（需使用 0.4.21 或更新的电脑连接包）；不显示 AI 中转站余额。
- OpenClaw 支持自动查找用户目录安装，可配置独立运行用户；聊天页可直接使用 SSH 终端。
- 原会话实时输出、历史合并与分页、运行状态、问题选项回答、等待消息队列、“引导”、停止、当前模型显示和切换。
- 问题支持整行选项、自定义回答、跳过单题/全部；提交前持久化请求 ID，送达不明时只核实状态，避免重复发送。
- 模型和推理强度使用展开选择器，只列出电脑报告支持的档位；代码块有独立复制按钮。
- Markdown、表格、代码、PDF 等本地文件链接、复制回复、完成时间、回到底部。
- 方形单行叠放缩略图、滑动切换、点按预览；图片位于文字气泡上方；滑动不触发打开或文件下载。
- 原图使用轻虚化浮窗，多图有上一张/下一张按钮；重复打开复用下载结果，预览下载不弹保存提示、不触发聊天跳底。
- 命令组默认仅显示最新摘要；展开按需读取，内部限定高度滚动。
- 照片/文件附件上传；文件分块下载、进度、取消、SHA-256 校验、保存、分享和导出到系统下载目录。
- 本机文件浏览、新建、文本编辑、重命名、删除、导入、系统打开/分享。
- SSH PTY 终端（xterm.js）、特殊按键、窗口尺寸同步；SFTP / 被动 FTP 浏览、上传、下载、新建和删除。
- AI 中转站模型获取、流式回复、经用户确认执行 SSH 命令；OpenClaw CLI 会话列表、历史、发送、停止。

文件下载上限 200 MB，单个附件上传上限 25 MB。普通 FTP 不加密；SSH/SFTP 使用主机指纹校验。OpenClaw 需在服务器先安装并启动 Gateway，命令名/容器可在连接配置中填写。

## 构建

环境：JDK 17 或 21、Python 3、Android SDK Platform 35、Build Tools 34+、NDK 28.2.13676358、SDK CMake 3.22.1；`ANDROID_HOME` 指向 SDK。Gradle Wrapper 已包含。

```powershell
python scripts/build-zerotier-android.py --sdk $env:ANDROID_HOME
cd Android
.\gradlew.bat :app:assembleDebug :app:lintDebug :app:testDebugUnitTest
```

调试 APK：`app/build/outputs/apk/debug/app-debug.apk`。发布构建运行 `:app:assembleRelease`，产出未签名 APK；用自己的长期 Android 发布证书通过 `apksigner` 签名。仓库不包含发布私钥。升级必须沿用相同 applicationId 和签名证书。

界面源码在 `web/`。修改后用 Node 22 执行：

```powershell
npm ci
npm run build
npm test
```

生成的 `app/src/main/assets/app.js` 与 `core.js` 一起提交，普通 Gradle 构建不需要 Node。构建将语法降到 Android 10 WebView 对应版本，并包含必要 polyfill。系统 WebView 建议保持更新。

导航回归检查：在仓库根目录运行 `node Android/tests/navigation.mjs`。使用本机 Chrome 无头浏览器和模拟原生桥，验证标签顺序、配对入口、跨设备状态隔离、聊天恢复及服务跳转；不连接真实电脑或服务器。可通过 `CHROME_PATH` 指定 Chrome 路径，结果保存在忽略提交的 `Build/`。

## 实现和验证

本地 WebView 仅渲染 APK 内置资源；网络、扫码、加密配对、文件操作、SSH 和 AI 调用均经原生 Java 层。聊天 WebView 不能导航到外部网页；公共外链在系统浏览器打开，主机网页使用没有原生桥的独立 WebView。Markdown 经 DOMPurify 清理。主机网页支持用户指定的 HTTP 本地服务，AI 接口仍要求 HTTPS；HTTPS 网页不忽略证书错误。

配对私钥、AI API Key 和 SSH 凭据存入 Android Keystore 保护的 AES-GCM 密文；密钥相互独立，系统备份与迁移不包含凭据。WebView 调试只在 debug 构建启用。

验证包括 Node ↔ Java 加密兼容、重放/篡改拒绝、HTTPS 模型与 SSE 流、历史合并、附件解析，以及 Android 15 模拟器通过真实 WSS 中转进行配对、排队/引导、图片与 PDF 下载联调；独立 SSH/SFTP 测试服务验证指纹确认、终端和文件传输。测试服务使用合成内容，不访问用户会话。

0.2.0 在独立私有网络通过实际 libzt 验证 FTP 读取/上传、512 KB 直连下载及 SHA-256 校验；主机网页的直连 HTTP、POST，以及 WSS 中转网页的 POST 和 WebSocket 回传均通过。网页代理的认证、目标主机/端口限制由 Java 单元测试覆盖；提问跳过与送达锁定、服务入口由浏览器回归检查覆盖。四种 ABI 均构建，原生库支持 16 KB 页面；运行验证使用 x86_64 Android 15 模拟器。

Android 10 为编译和 API 兼容目标；仍需在对应真机验证系统扫码、相册、厂商后台管理和分享菜单。后台连接可能受系统省电限制，回到前台会重新同步；通知仅针对保持连接时收到的完成事件。OpenClaw 和实际 AI 提供商的端到端效果取决于用户服务器配置。

## 第三方许可

- OkHttp / Okio / Kotlin 标准库：Apache-2.0。
- Bouncy Castle：MIT 类许可证；JSch (mwiede)：BSD-3-Clause。
- Apache Commons Net：Apache-2.0；ZXing：Apache-2.0。
- marked、xterm.js 与 fit addon：MIT；DOMPurify：Apache-2.0 或 MPL-2.0。
- AndroidX WebKit：Apache-2.0。libzt 及固定子模块的完整许可见 App 内 **服务 → ZeroTier → 开源许可**。

内置前端库对应许可证保存在 `app/src/main/assets/vendor/`。Gradle 下载的 Java 依赖及其元数据保留各自许可。esbuild 仅用于开发时构建，MIT。

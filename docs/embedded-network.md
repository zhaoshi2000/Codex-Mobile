# 内置 ZeroTier 与主机服务

AstroGate 的 iOS 和 Android 客户端使用 libzt 用户态网络栈，不调用或依赖手机上的 ZeroTier App，也不安装系统 VPN。服务 → ZeroTier 中填写网络 ID、启用网络，并在网络管理后台授权显示的节点 ID。节点身份保存在 App 的受保护数据目录中，关闭再开启复用身份。删除 App 会删除其身份。

## 使用

- FTP：服务 → 添加 FTP → 通过内置 ZeroTier 连接。主机填写网络内 IP；控制端口和 EPSV/PASV 数据端口均走内置网络。FTP 服务器需要监听 ZeroTier 地址或所有网卡，并允许被动数据端口。
- 文件：点击电脑发来的文件链接或浏览电脑文件，选择「服务器中转下载」或「ZeroTier 直连下载」。直连也需要已配对电脑在线完成文件授权，随后文件数据通过 ZeroTier 传输；两条路径都校验长度和 SHA-256。
- 网页：服务 → 主机网页服务，选择电脑、填写网址及电脑的 ZeroTier IP。也可点击聊天里的本机/内网网页链接选择通道。保留原 URL 的路径、端口、Cookie、HTTPS 证书验证和 WebSocket 升级。仅所选主机走该网页代理，公共 CDN 资源走手机正常网络。中转目标是已配对电脑本机；直连服务必须监听该电脑的 ZeroTier 网卡。
- 关闭 ZeroTier 后服务器中转仍可用。关闭网页窗口会回收其代理与连接。

直连下载地址是通过已配对加密连接取得的短期能力链接，不是长期公开分享链接。电脑仅在 ZeroTier 网卡上监听；过期或释放文件后失效，服务端只读取经过原有授权检查的文件快照。网页中转仅允许本机/本机 ZeroTier 地址，每部手机最多 8 条连接，断线清理。

## 构建

需要 Xcode、Python 3 和 CMake。首次构建前执行：

```bash
python3 scripts/build-zerotier.py
```

脚本固定 libzt 与三个子模块的提交，禁用已移除的 bitcode 标志，生成 `Build/ZeroTier/zt.xcframework`（iPhone arm64、Apple Silicon 模拟器 arm64）。不将二进制或节点私钥提交进 Git。第三方许可随 App 打包，服务 → ZeroTier → 开源许可可查看。

## 验证

- `node --test Connect/test/*.test.mjs`：文件授权、快照能力链接过期、网页连接所属手机隔离、限制目标、提问跳过与幂等提交。
- `Tests/EmbeddedNetworkSmoke.swift`：在独立私有测试网络中使用实际 iOS SDK，验证 HTTP、FTP 上传/下载字节一致性，以及停启后身份复用。测试需要授权测试节点，完成后撤销并删除测试网络。
- HTTPS 自签证书不会自动忽略验证；安装可信证书或使用已有有效证书。

Android 10 及以上从 0.2.0 支持这些入口。运行 `python scripts/build-zerotier-android.py --sdk <Android SDK 路径>`，使用 NDK 28.2.13676358 和 CMake 3.22.1 构建四种 ABI，随后按 [Android 构建说明](../Android/README.md)生成 APK。SDK 与 iOS 使用相同固定源码版本；JNI 包装修复阻塞 I/O 持有 GC 临界数组、偏移写入和关闭节点错误分离 Java 线程的问题。产物保存在忽略提交的 `Build/AndroidZeroTier/`。

Android 网页使用带随机认证的本地 HTTP/CONNECT 代理，只有所选主机和端口允许通过；代理凭据不会转发给网页服务。代理绑定 127.0.0.1，远程 WebView 没有原生桥，关闭窗口回收连接和代理配置。需要系统 WebView 支持 AndroidX 的代理覆盖与反向排除规则，旧版本会提示更新。配置依据 [AndroidX ProxyConfig 文档](https://developer.android.com/reference/androidx/webkit/ProxyConfig.Builder)。

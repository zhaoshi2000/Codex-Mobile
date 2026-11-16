# Android 0.1.0 — 2026-11-16

首次提供 Android 10+ APK：本机文件、SSH/SFTP/FTP、电脑 Codex 和服务器 AI/OpenClaw。复用现有加密配对与消息协议，包含排队引导、图片预览缓存、文件下载进度、模型选择、对话管理和命令折叠。源码、构建与验证范围见 Android/README.md。

# Changelog

## 0.3.3
- 增加蓝色文件夹 App 图标，配置 `AppIcon` 资源目录，修复安装后白色空白图标。

## 0.3.2
- 文件首页隐藏完整沙盒路径，并提供新建 Markdown 文件入口；`.md` 文件可直接编辑和保存。
- SSH 终端过滤常见 ANSI 控制序列，并保留跨数据块的 UTF-8 字符。
- SSH 认证失败时显示更明确的原因，主机密钥探测在认证前停止。

## 0.3.1
- 改进 SSH 连接失败诊断。

## 0.3.0
- 将 Bundle ID 更新为本次签名描述文件对应的 `com.example.AstroGate`。
- 配置 Team ID、Ad Hoc provisioning profile UUID 和 iPhone Distribution 签名身份。
- 增加 `swift-crypto` 的显式 Crypto 产品依赖，供 SSHService 中的 `import Crypto` 使用。
- 增加 `ExportOptions.plist` 和 macOS 自动 Archive/导出 IPA 脚本。
- 增加签名文件放置说明与私密凭据 `.gitignore` 规则。

## 0.2.0
- 增加 SSH 私钥认证和 PTY 终端会话。
- 增加文本编码读取支持与传输进度。

# AstroGate Connect — 0.4.19-pc2

手机在 AstroGate 管家的 Codex 页选择电脑 → 项目 → 原对话。执行仍由该电脑的 Codex 桌面版负责，使用电脑现有登录和会话设置。无需把 OpenAI 密钥传给手机或中转。

## 已实现

0.4.15：运行中发送进入 Desktop 原生持久队列（reserve/complete v3），关闭手机后仍由电脑接续。等待区可“引导”或移除手机发起的消息；从电脑发起的等待消息也会显示，继续在电脑管理。引导先原子移出原生队列，已消费消息不能重发，结果不明时不自动重试。图片按需传输 240×240 JPEG 缩略图，手机内存缓存最多 36 张 / 8 MB；点按才下载原图。命令折叠摘要只显示组内最新一条，不包含命令输出。


0.4.9：历史/实时消息包含 startedAtMs 和有界 commandExecution 折叠摘要，commandDetails 仅按需返回指定会话/轮次内的命令记录（命令最多 16K 字符、输出末尾 32K 字符）。不返回推理内容。手机按原始时间排序并按连续轮次显示。

0.4.8：history 按可见消息而非底层条目计数，原游标逐页推进，超过字节预算重试同一游标；Swift 窗口按共享消息锚点合并历史与实时流，延迟历史不抹掉实时消息。unwatch 接受 threadId，避免旧视图关闭新订阅。

0.4.7 新增 `navigation` / `pinThread` / `markRead` / `models` / `setModel` / `forkThread`。`threads.limit=20` 返回 20 条；省略仍兼容旧版 10 条。置顶覆盖和已读时间按已配对手机公钥隔离，`navigation.json` 只存元数据。运行状态由桌面 v13 快照/补丁提供，观察到 active→idle 后持久记录完成时间。断线期间没有观测到的事件不推断为完成。

模型通过 Desktop owner 的 read-model-settings / update-thread-settings v2 读取与更新，只允许当前供应商列表中的模型，保留兼容的推理强度，不改变权限。运行中消息默认进入桌面原生等待队列，只有点“引导”才使用 follower-steer-turn；空闲时使用 start-turn，均复用去重账本。分支调用短生命周期 app-server 的 thread/fork(lastTurnId)，释放写锁后交给 Desktop，禁止自动延续继承目标。

- 多电脑二维码配对，电脑身份固定，手机密钥保存在 Keychain。
- 默认读取本机 Codex 的项目名称和真实会话归属；项目和最近对话同屏显示。对话按更新时间倒序，手机默认每次 20 条，“更多”加载下一页。
- `desktopCatalog: true` 时读取 `codexHome/.codex-global-state.json` 的本机项目映射，并通过本机 app-server 读取当前账号的原会话。不会把工作目录当成项目，也不会扫描服务器上的 Codex。关闭该选项可继续使用原来的 `projects` 目录限制模式。
- 原会话历史分页、实时回复、发送去重、停止当前轮次。手机前台保活，断线和回到前台自动重连；iOS 后台可能暂停网络，恢复时使用已配对身份，无需新二维码。
- 手机只在内存中保存当前屏幕：最多 100 条聊天消息、100 条命令摘要 / 512 KB 文本。单次历史至多 50 条可见聊天消息和 100 条命令摘要（跳过工具/推理记录，每次最多扫描 100 页底层记录，超出可继续分页） / 约 230 KB；长消息截取 16,000 字符。上一页替换屏幕，回到最新恢复实时显示，不下载整个历史库。
- 项目文件通过电脑 → 中转 → 手机分块下载，最大 200 MB，SHA-256 完整性校验。手机保存到“文件 / Codex 下载”，同名文件不覆盖。
- X25519 + HKDF-SHA256 + AES-256-GCM 消息加密；随机连接挑战和严格序号防重放；远端连接必须 WSS。此协议尚未经独立安全审计。
- 中转不保存聊天或文件，电脑离线无法发消息或下载。文件快照仅在电脑临时目录保留至下载结束或租约清理（10 分钟）。

## 运行任务摘要

`activity` 使用本机当前账号目录发现桌面拥有的会话，跟踪 Desktop stream v13 的 `threadRuntimeStatus`，不使用独立 app-server 的 `notLoaded` 状态来判断运行与否。目录最多每 15 秒刷新一次，手机首页每 5 秒取摘要；初次扫描上限 5000 个非归档会话，超出时明确显示提示。

仅保留任务标题、项目名称、运行状态和 revision；首页不保留完整会话快照，不把历史库复制到服务器或手机。打开原会话时才按需读取聊天。桌面通道断开清除旧状态并显示状态不可用。

## 附件与提醒

照片和文件走同一端到端加密连接，192 KiB 分块、SHA-256 校验；每条最多 6 个附件，单个 25 MB。服务端只转发密文。已上传文件留在原对话工作目录 `.ifile-attachments/<UUID>/`，供电脑原会话和后续任务读取；手机发送成功清除临时副本。上传中的临时文件 10 分钟失效，失败不提交对话。发送去重摘要包含附件 ID；未知送达时沿用同一消息 ID 和附件集合。

图片使用桌面 `localImage` 输入，普通文件使用 `mention` 输入。链接下载允许原工作目录，以及该对话 assistant 消息中明确提供的单个绝对文件链接；其他路径仍拒绝。已确认的附件保留在电脑，需清理时应确保旧会话不再引用。

设置页可启用本地完成通知。电脑监视手机发起的轮次，页面切换不停止任务；手机重连可补查最近 24 小时的完成记录。未配置 APNs，因此 App 被系统挂起/退出时不是后台实时推送。完整工具卡片和审批在电脑处理。

## 当前边界

这是测试版，实测 Windows Codex Desktop `26.1111.2228.0` / bundled engine `0.169.0-alpha.11.1` / desktop stream v13。桌面 IPC 属于版本相关适配，升级后先运行 doctor 并重新联调。Mac / Linux 桌面 IPC 尚未验证。

对话必须由桌面应用打开并持有。手机点进对话后若桌面尚未持有，将请求系统打开 `codex://threads/...`。连接程序不启动第二个执行引擎，也不改写原会话数据库。

本版显示聊天 Markdown、附件链接、执行状态和交互问答。普通操作审批仍在电脑处理。手机可新建项目内或无项目对话、确认后永久删除空闲对话；使用原生 app-server 接口，不写数据库或全局状态文件。新建项目仍在电脑完成。文件下载允许已选项目/对话目录，或当前对话中 assistant 明确提供的单个文件链接；后者不会授予父目录访问权。

手机发送结果不明确时保留同一个消息 ID，重试不会再次执行。请先刷新历史核实，不要复制内容换新 ID 重发。连接程序重启后仍保留去重记录；不要随意删除 `operations.json`。

## 电脑运行

另一台 Windows x64 电脑可以使用同一便携包、同一中转服务；每台电脑分别首次配置并扫码配对。不需要额外安装 Node.js/Python，不需要复制原电脑源码或配置目录。电脑需要保持开机联网并运行 Codex 桌面版。Windows ARM64 尚未验证。

0.4.19-pc2 增加独立安装版和正在运行的 Codex 安装目录识别；原路径因更新失效时会重新查找，只更新可执行文件路径，保留电脑身份与配对。二维码仅保存在用户状态目录，不再复制到桌面。打包可运行 `python Connect/package-windows.py --runtime <包含官方 Windows x64 node.exe 和 LICENSE 的目录>`，依赖须先在 Connect 内安装。

Windows x64 便携包解压后，双击 `Open AstroGate Connect.cmd`。它使用包内的 Node.js 和依赖。请先打开并登录 Codex 桌面版。已配置的电脑直接出码，首次配置的电脑输入自己的中转 WSS 地址和连接密钥。密钥和配对状态保存在当前 Windows 用户目录。若需要修改中转配置，先停止当前连接进程，再运行 `"Open AstroGate Connect.cmd" -Configure`。

中转管理员可在 HTTPS 管理页复制 WSS 地址、创建连接密钥，再粘贴到首次配置窗口。现有 Nginx `/ifile-connect/` 路径下，管理页通常是 `https://你的域名/ifile-connect/admin/`。后台登录密码与连接密钥不同，不要在连接窗口输入后台登录密码。新生成的连接密钥只展示一次，后续可撤销；撤销后使用该密钥的电脑需要更新配置。服务器尚未部署新管理服务时，继续使用原来的 WSS 地址和连接密钥。

手动运行源码时，需要 Node.js 22+，打开且登录 Codex 桌面版。

1. `npm ci --ignore-scripts`
2. 复制 `bridge.config.example.json` 为 `bridge.config.json`，填入实际路径和中转 WSS 地址。
3. 用环境变量 `IFILE_RELAY_TOKEN` 提供中转连接密钥，不要写进源码或分享二维码；后台登录密码另行配置。
4. `npm run doctor -- bridge.config.json`
5. `npm run bridge -- bridge.config.json`
6. 用 iFile+ → Codex → + 扫描程序提示位置的 `pairing.png`；两分钟内有效且只能用于一部新手机。过期不撤销已配对身份，也不会断开已建立的连接。

Windows 使用 `start.ps1 -Config 完整配置路径` 启动并显示桌面二维码、倒计时和连接设备数量。程序已运行时只刷新配对码，保持原连接；`-Restart` 用于更新代码后显式重启，`stop.ps1` 停止。启动脚本从配置的 stateDir 内 `relay.token` 读取中转密钥；该目录应只允许当前 Windows 用户访问。安装依赖和配置凭据需先完成。关闭二维码窗口不会停止连接。运行 `install-autostart.ps1` 可安装当前用户的 Windows 登录自启，后台 watchdog 每 30 秒检查一次连接进程，并在 Codex 未运行时启动桌面应用。`start.ps1 -EnsureRunning -NoShowQR` 只检查和启动，不刷新已有二维码。不会自动登录 Windows 或修改休眠设置。

0.4.29 Windows 便携包包含登录自启脚本；成功打开连接程序后自动安装当前用户登录自启。请保留解压目录，重启后登录 Windows 并联网，连接程序会自动恢复，原配对保留。未登录 Windows、关机或休眠期间无法连接。旧版便携包需要更新后打开一次。

若需彻底停用自启，删除当前用户“启动”文件夹中的 `iFilePlus Connect.lnk`，停止命令行为本项目 `watchdog.ps1` 的 PowerShell 进程，再运行 `stop.ps1`。仅 stop 会被 watchdog 恢复。

每台电脑使用独立 stateDir（默认用户目录 `.ifileplus-connect`）。该目录包含私钥和配对信任记录，禁止上传仓库或共享。手机保存电脑公钥，公钥改变必须先核实并移除旧设备。

撤销所有手机：先停止电脑连接程序，运行 `node src/revoke.mjs bridge.config.json`，再重新启动。仅从手机移除设备不等于电脑撤销信任。停止电脑程序会立即断开远程连接。

## 中转部署

Dockerfile 只包含 Node 中转代码。设置随机 32 字符以上的 `IFILE_RELAY_TOKEN` 作为兼容旧电脑的连接密钥；管理后台另设 `IFILE_RELAY_ADMIN_PASSWORD`，不得与连接密钥相同。容器端口 8787 只绑定服务器回环地址，前面用已有 HTTPS 反向代理。不要直接把未加 TLS 的中转端口开放到公网。

管理后台使用同一 HTTPS 入口的 `/ifile-connect/admin/`。启动中转时设置 `IFILE_RELAY_ADMIN_PASSWORD`（至少 20 字符）、`IFILE_RELAY_CONFIG_PATH=/data/relay-admin.json` 和 `IFILE_RELAY_PUBLIC_WSS=wss://你的域名/ifile-connect`；将服务器上的持久目录挂载为容器 `/data`，并给容器用户写权限。浏览器使用用户名 `admin` 和单独的后台密码登录。后台可复制 WSS 地址、查看在线连接数、创建或停用电脑连接密钥。新密钥仅在创建时展示一次，配置文件只保存其 SHA-256 摘要；原 `IFILE_RELAY_TOKEN` 继续有效，旧电脑不用重新配对。停用密钥后，该电脑下一次连接会被拒绝，需在电脑端更新密钥。修改页面中的 WSS 地址只改变提供给电脑复制的地址；域名、证书和 Nginx 路由仍需在服务器配置。

若启用独立语音中转，给语音容器只读挂载同一 `/data/relay-admin.json` 并设置相同的 `IFILE_RELAY_CONFIG_PATH`，新密钥才能用于语音输入；停用新密钥对语音请求立即生效。后台密码、连接密钥和私有配置目录不得上传源码仓库。

示例 Nginx 独立路径（`proxy_pass` 末尾 `/` 必须保留）：

```nginx
location ^~ /ifile-connect/ {
    proxy_pass http://127.0.0.1:18787/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 90s;
    proxy_send_timeout 90s;
    client_max_body_size 1m;
    access_log off;
}
```

电脑 relay 配为 `wss://你的域名/ifile-connect`。服务端 `/health` 返回健康状态。中转不信任代理传入的 IP，当前限流按直连代理地址累计，因此此版本适合个人小规模使用。

## 验证

`npm test` 覆盖密钥协商、密文篡改、序号和跨连接重放、一次配对、可信手机重连、并发消息去重、未知送达状态、目录穿越 / junction 越界、文件下载 hash 和桌面 patch 版本。

本机实测完整链路：本地中转 → 加密模拟手机 → 桌面原测试会话，收到 `IFILE_E2E_OK`；能列出原会话、读取已有回复、收到实时状态和校验下载文件。iOS 真机扫码、后台恢复和公网网络切换需安装后继续验收，不能由 Node 模拟测试代替。

## 0.4.4 问题与流式更新

Desktop v13 的 `turns` 可能为空，当前通过 `turnHistory.history.islands` 顺序与 `entitiesByKey` 读取 canonical turns；旧 turns 结构继续兼容。

异步问题由 `agentMessage.questions` 投影，原生 `questionItemId` 保持不变，使用 Desktop 原生结构化回复及 follower steer/start；同步问题保留请求 ID 的数值/字符串类型，使用 follower-submit-user-input。只处理用户问题，权限审批仍交回桌面。

手机订阅原会话后才能提交答案；桥接按问题与提交 ID 去重，未知送达不重试。Desktop 通道重连时丢弃旧快照，收到新快照前拒绝作答。运行摘要仅显示状态和工具类型，不传递 reasoning 内容。

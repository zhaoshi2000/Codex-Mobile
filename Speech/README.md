# 实时语音输入

iPhone 0.4.24 点击输入框旁的语音图标，按住说话，边说边显示文字；松开后追加到原草稿并切回键盘，可编辑后手动发送。上滑超过取消区域后松开会丢弃本次录音。不会自动发送消息。单次最长 60 秒，离开聊天或录音时切到后台会停止录音。

默认使用 **手机本地中文识别**（Apple Speech，zh-CN）。同时要求 `supportsOnDeviceRecognition` 和 `requiresOnDeviceRecognition`，不支持时显示原因，不会自动转交云端。首次使用需允许麦克风和语音识别权限；授权弹窗结束后重新按住说话。系统需要具备中文离线识别资源。本地识别无需电脑和中转在线，但向 Codex 发送文字仍需连接电脑。

识别方式菜单可手动切换到 **服务器 CPU**，沿用下方部署。识别快照替换当前文字，不把每次局部结果拼接；录音会话隔离，最终结果只提交一次。CPU 模式增加停顿分句和束搜索，不会简单删除重复字（“看看”“试试”等正常词会保留）。真实准确率仍取决于麦克风、环境、语速及系统模型，发送前可编辑。

## 服务器 CPU 模式数据流

手机通过现有配对加密通道把 16 kHz、单声道 PCM16 分片送到电脑连接程序。电脑使用已有中转凭据请求同一中转地址的 `/speech`，服务器经 SSH 反向隧道转交 CPU 工作机。识别结果沿原通道返回。因此录音时，已绑定电脑、CPU 工作机和中转服务器均需在线。

语音不会写入项目文件或聊天记录，也不会调用系统云识别或第三方语音 API。录音仅在手机内存中短暂排队；CPU 仅保留流式模型状态和结果，空闲 90 秒后清理。录音分片带序号和随机会话标识，丢包重试不会重复处理；完成后释放识别流。

## 工作机

推荐 Python 3.12。在 `/opt/astrogate-speech` 建立虚拟环境，安装 `requirements.txt`，复制 `worker.py`。创建无登录权限的系统用户 `astrogate-speech`，确保该用户可读取 Python 环境和模型。

使用 [sherpa-onnx 官方中英双语流式 Zipformer 模型](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/online-transducer/zipformer-transducer-models.html#csukuangfj-sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20-bilingual-chinese-english)。从模型仓库 `csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20` 下载以下文件到 `/opt/astrogate-speech/model`：

- `encoder-epoch-99-avg-1.int8.onnx`
- `decoder-epoch-99-avg-1.int8.onnx`
- `joiner-epoch-99-avg-1.int8.onnx`
- `tokens.txt`

安装 `astrogate-speech.service` 到 systemd，然后启用。服务只监听 `127.0.0.1:18890`，强制 `provider=cpu`，默认 4 个计算线程，并限制内存和 CPU 使用。

```sh
systemctl daemon-reload
systemctl enable --now astrogate-speech
curl http://127.0.0.1:18890/health
```

工作机以独立 SSH 密钥建立持久隧道，使用 systemd 自动重连：

```sh
ssh -NT -o BatchMode=yes -o IdentitiesOnly=yes \
  -o ExitOnForwardFailure=yes -o ServerAliveInterval=20 -o ServerAliveCountMax=3 \
  -o StrictHostKeyChecking=yes -i /path/to/dedicated-key \
  -R 127.0.0.1:18891:127.0.0.1:18890 user@relay-server
```

预先核对并保存服务器主机公钥。服务器端该密钥应限制为 `restrict,port-forwarding,permitlisten="127.0.0.1:18891",permitopen="127.0.0.1:1",command="/bin/false"`，不能执行远程命令或转发其他服务。

## 中转服务器

使用 Node 22 运行 `Connect/src/speech-relay.mjs`。配置 `IFILE_RELAY_TOKEN` 为现有电脑中转凭据；不得放入 App、源码或公开下载包。默认仅监听 `127.0.0.1:18892`，工作机地址为 `http://127.0.0.1:18891/stream`，可通过 `SPEECH_WORKER_URL` 修改。

在现有 TLS 虚拟主机添加精确路径（按实际 Codex 中转前缀修改）：

```nginx
location = /ifile-connect/speech {
    proxy_pass http://127.0.0.1:18892/speech;
    proxy_read_timeout 20s;
    proxy_send_timeout 15s;
    client_max_body_size 90k;
    proxy_request_buffering off;
    access_log off;
}
```

如果以 Docker 运行，使用 host 网络访问宿主机回环隧道端口；设置只读文件系统、资源限制及 `unless-stopped` 重启策略。现有 Codex WebSocket 中转无需重启。

电脑更新到 0.4.23 连接包后自动使用原中转地址和凭据，无需重新配对。其他服务器需自行部署本节服务，不能只更新客户端。

## 验证

```sh
node --test Connect/test/speech.test.mjs
cd Speech
python -m unittest test_worker -v
```

覆盖鉴权、大小限制、实时返回、乱序拒绝、重复分片去重、取消、会话过期、设备隔离及离线提示。真实模型识别准确率受口音、噪声和麦克风影响；编辑草稿后再发送。

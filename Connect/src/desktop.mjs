// Protocol adapter informed by Remodex (Apache-2.0). See THIRD_PARTY_NOTICES.
// Only forwards actions to the existing Desktop owner. It never starts a competing engine.
import net from "node:net";
import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
export class DesktopIPC extends EventEmitter {
  constructor(socketPath = "\\\\.\\pipe\\codex-ipc", { retryMs = 3000, timeoutMs = 15000 } = {}) {
    super();
    this.path = socketPath;
    this.pending = new Map();
    this.buffer = Buffer.alloc(0);
    this.clientId = "initializing-client";
    this.followed = new Set();
    this.stopping = false;
    this.connected = false;
    this.retryMs = retryMs;
    this.timeoutMs = timeoutMs;
    this.lastError = null;
  }
  connect() {
    if (this.stopping) return Promise.reject(new Error("桌面通道已关闭"));
    if (this.connecting) return this.connecting;
    if (this.connected) return Promise.resolve();
    clearTimeout(this.retry);
    this.connecting = this.open().finally(() => { this.connecting = null; });
    return this.connecting;
  }
  async open() {
    this.buffer = Buffer.alloc(0);
    this.clientId = "initializing-client";
    const socket = net.createConnection(this.path);
    this.socket = socket;
    socket.on("error", error => {
      if (this.socket === socket) this.lastError = "Codex 桌面通道错误：" + (error.code || "连接中断");
    });
    socket.on("data", b => { if (this.socket === socket) this.read(b); });
    socket.on("close", () => {
      if (this.socket !== socket) return;
      this.connected = false;
      if (!this.stopping && !this.lastError) this.lastError = "Codex 桌面通道已断开，正在重新连接";
      for (const p of this.pending.values()) {
        clearTimeout(p.timer);
        p.reject(new Error("桌面通道已断开"));
      }
      this.pending.clear();
      this.buffer = Buffer.alloc(0);
      this.emit("closed");
      if (!this.stopping) {
        clearTimeout(this.retry);
        this.retry = setTimeout(() => this.connect().catch(() => {}), this.retryMs);
      }
    });
    try {
      await new Promise((resolve, reject) => {
        const timer = setTimeout(() => socket.destroy(new Error("Codex 桌面连接超时")), this.timeoutMs);
        const finish = error => {
          clearTimeout(timer);
          socket.off("connect", onConnect); socket.off("error", onError); socket.off("close", onClose);
          error ? reject(error) : resolve();
        };
        const onConnect = () => finish();
        const onError = error => finish(error);
        const onClose = () => finish(new Error("桌面通道已断开"));
        socket.once("connect", onConnect); socket.once("error", onError); socket.once("close", onClose);
      });
      const r = await this.request(
        "initialize",
        { clientType: "ifileplus-connect" },
        1,
      );
      if (typeof r.result?.clientId !== "string" || !r.result.clientId) throw new Error("Codex 桌面握手响应无效");
      if (this.stopping || socket.destroyed) throw new Error("桌面通道已断开");
      this.clientId = r.result.clientId;
      this.connected = true;
      this.lastError = null;
      for (const id of this.followed) this.follow(id);
      this.emit("connected");
    } catch (error) {
      this.lastError = error.message;
      socket.destroy();
      throw error;
    }
  }
  reconnect(reason) {
    this.lastError = reason;
    this.connected = false;
    // A transport failure is recoverable. Only close() disables reconnection.
    this.socket?.destroy();
  }
  read(b) {
    this.buffer = Buffer.concat([this.buffer, b]);
    while (this.buffer.length >= 4) {
      const size = this.buffer.readUInt32LE();
      if (size > 32 * 1024 * 1024) {
        this.reconnect("Codex 桌面同步数据超过 32 MB，正在重新连接");
        return;
      }
      if (this.buffer.length < size + 4) return;
      const raw = this.buffer.subarray(4, 4 + size);
      this.buffer = this.buffer.subarray(4 + size);
      let m;
      try {
        m = JSON.parse(raw);
      } catch {
        this.reconnect("Codex 桌面同步数据格式无效，正在重新连接");
        return;
      }
      if (!m || typeof m !== "object" || Array.isArray(m)) {
        this.reconnect("Codex 桌面同步数据格式无效，正在重新连接");
        return;
      }
      if (m.type === "response") {
        const p = this.pending.get(m.requestId);
        if (p) {
          this.pending.delete(m.requestId);
          clearTimeout(p.timer);
          m.resultType === "error"
            ? p.reject(new Error(String(m.error)))
            : p.resolve(m);
        }
      }
      if (m.type === "client-discovery-request")
        this.write({
          type: "client-discovery-response",
          requestId: m.requestId,
          response: { canHandle: false },
        });
      if (m.type === "broadcast") this.emit("broadcast", m);
    }
  }
  write(m) {
    if (!this.socket || this.socket.destroyed)
      throw new Error("手机已连接电脑，但连接程序与 Codex 桌面的通道已断开，正在自动重连");
    const b = Buffer.from(JSON.stringify(m));
    const h = Buffer.alloc(4);
    h.writeUInt32LE(b.length);
    this.socket.write(Buffer.concat([h, b]));
  }
  request(method, params, version = 1, targetClientId) {
    return new Promise((resolve, reject) => {
      const requestId = randomUUID();
      const timer = setTimeout(() => {
        this.pending.delete(requestId);
        reject(new Error("桌面未确认操作，发送结果待核实"));
        // Never replay an uncertain send. Reconnect and resubscribe only.
        this.reconnect("Codex 桌面响应超时，正在重新连接；未确认的消息请勿重复发送");
      }, this.timeoutMs);
      this.pending.set(requestId, { resolve, reject, timer });
      try {
        this.write({
          type: "request",
          requestId,
          sourceClientId: this.clientId,
          version,
          method,
          params,
          ...(targetClientId ? { targetClientId } : {}),
        });
      } catch (e) {
        clearTimeout(timer);
        this.pending.delete(requestId);
        reject(e);
      }
    });
  }
  async owner(threadId) {
    const owner = (
      await this.request("thread-owner-discovery", {
        hostId: "local",
        conversationId: threadId,
      })
    ).handledByClientId;
    if (!owner) throw new Error("请先在电脑打开此对话");
    return owner;
  }
  follow(threadId, following = true) {
    following ? this.followed.add(threadId) : this.followed.delete(threadId);
    this.write({
      type: "broadcast",
      sourceClientId: this.clientId,
      version: 1,
      method: "thread-stream-following-changed",
      params: { hostId: "local", conversationId: threadId, following },
    });
  }
  async send(threadId, text, messageId, attachments = []) {
    const owner = await this.owner(threadId);
    return this.request(
      "thread-follower-start-turn",
      {
        conversationId: threadId,
        turnStart: {
          request: {
            threadId,
            input: [{ type: "text", text: text || "请查看附件", text_elements: [] }, ...attachments.map(a => a.image ? { type: "localImage", path: a.path } : { type: "mention", name: a.name, path: a.path })],
            clientUserMessageId: messageId,
          },
          context: { inheritThreadSettings: true },
        },
      },
      2,
      owner,
    );
  }
  async steer(threadId, text, messageId, attachments = []) {
    const owner = await this.owner(threadId);
    return this.request("thread-follower-steer-turn", {
      conversationId: threadId, clientUserMessageId: messageId,
      input: [{ type: "text", text: text || "请查看附件", text_elements: [] }, ...attachments.map(a => a.image ? { type: "localImage", path: a.path } : { type: "mention", name: a.name, path: a.path })],
      restoreMessage: { id: messageId, text, createdAt: Date.now(), context: { workspaceRoots: [], commentAttachments: [] } },
    }, 1, owner);
  }
  // Reserve/complete inserts one native queued message without replacing other
  // Desktop windows' queue. Desktop persists it and owns automatic dispatch.
  async queue(threadId, text, messageId, attachments = [], cwd) {
    const owner = await this.owner(threadId);
    const message = { id: messageId, text: text || "请查看附件", createdAt: Date.now(), acceptedAtMs: Date.now(), cwd,
      context: { prompt: text || "请查看附件", addedFiles: [], commentAttachments: [],
        fileAttachments: attachments.filter(a => !a.image).map(a => ({ label: a.name, path: a.path, fsPath: a.path })),
        imageAttachments: attachments.filter(a => a.image).map(a => ({ src: a.path, localPath: a.path, filename: a.name })) } };
    const write = value => this.request("thread-follower-set-queued-follow-ups-state", {
      conversationId: threadId, state: { [threadId]: [value] }, preparationMessageId: messageId,
    }, 3, owner);
    await write({ ...message, preparation: {} });
    await write(message);
  }
  async removeQueued(threadId, messageId) {
    const owner = await this.owner(threadId);
    const reply = await this.request("thread-follower-remove-queued-message", { conversationId: threadId, messageId }, 1, owner);
    return reply.result?.removed;
  }
  async modelSettings(threadId) {
    const owner = await this.owner(threadId);
    const reply = await this.request("thread-follower-read-model-settings", { conversationId: threadId }, 1, owner);
    return reply.result?.settings || {};
  }
  async setModel(threadId, model, effort) {
    const owner = await this.owner(threadId);
    const reply = await this.request("thread-follower-update-thread-settings", { conversationId: threadId, threadSettings: { model, ...(effort ? { effort } : {}) } }, 2, owner);
    if (!reply.result?.applied) throw Error("电脑未应用模型设置，请刷新后重试");
    return this.modelSettings(threadId);
  }
  async answer(threadId, group, response, messageId, active) {
    const owner = await this.owner(threadId);
    if (group.kind === "sync") return this.request("thread-follower-submit-user-input", { conversationId: threadId, requestId: group.requestId, response }, 1, owner);
    if (!active) return this.send(threadId, response, messageId);
    return this.request("thread-follower-steer-turn", { conversationId: threadId, clientUserMessageId: messageId, input: [{ type: "text", text: response, text_elements: [] }], restoreMessage: { id: messageId, text: response, createdAt: Date.now(), context: { workspaceRoots: [], commentAttachments: [] } } }, 1, owner);
  }
  async stop(threadId, turnId) {
    const owner = await this.owner(threadId);
    return this.request(
      "thread-follower-interrupt-turn",
      { conversationId: threadId, mode: "user-stop", expectedTurnId: turnId },
      4,
      owner,
    );
  }
  close() {
    this.stopping = true;
    this.connected = false;
    clearTimeout(this.retry);
    for (const id of this.followed) {
      try {
        this.follow(id, false);
      } catch {}
    }
    this.socket?.destroy();
  }
}

// Protocol adapter informed by Remodex (Apache-2.0). See THIRD_PARTY_NOTICES.
// Only forwards actions to the existing Desktop owner. It never starts a competing engine.
import net from "node:net";
import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
export class DesktopIPC extends EventEmitter {
  constructor(socketPath = "\\\\.\\pipe\\codex-ipc") {
    super();
    this.path = socketPath;
    this.pending = new Map();
    this.buffer = Buffer.alloc(0);
    this.clientId = "initializing-client";
    this.followed = new Set();
    this.stopping = false;
    this.connected = false;
  }
  async connect() {
    this.buffer = Buffer.alloc(0);
    this.clientId = "initializing-client";
    await new Promise((resolve, reject) => {
      this.socket = net.createConnection(this.path);
      this.socket.once("connect", resolve);
      this.socket.once("error", reject);
      this.socket.on("error", () => {});
      this.socket.on("data", (b) => this.read(b));
      this.socket.on("close", () => {
        this.connected = false;
        for (const p of this.pending.values()) {
          clearTimeout(p.timer);
          p.reject(new Error("桌面通道已断开"));
        }
        this.pending.clear();
        this.emit("closed");
        if (!this.stopping) {
          clearTimeout(this.retry);
          this.retry = setTimeout(() => this.connect().catch(() => {}), 3000);
        }
      });
    });
    const r = await this.request(
      "initialize",
      { clientType: "ifileplus-connect" },
      1,
    );
    this.clientId = r.result.clientId;
    this.connected = true;
    for (const id of this.followed) this.follow(id);
    this.emit("connected");
  }
  read(b) {
    this.buffer = Buffer.concat([this.buffer, b]);
    while (this.buffer.length >= 4) {
      const size = this.buffer.readUInt32LE();
      if (size > 32 * 1024 * 1024) {
        this.close();
        return;
      }
      if (this.buffer.length < size + 4) return;
      const raw = this.buffer.subarray(4, 4 + size);
      this.buffer = this.buffer.subarray(4 + size);
      let m;
      try {
        m = JSON.parse(raw);
      } catch {
        this.close();
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
      throw new Error("Codex 桌面未连接");
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
      }, 15000);
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

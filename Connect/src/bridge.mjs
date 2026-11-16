import { speechClient } from "./speech.mjs";
import { WebSocket } from "ws";
import { randomUUID, randomBytes } from "node:crypto";
import path from "node:path";
import os from "node:os";
import fs from "node:fs/promises";
import { pathToFileURL } from "node:url";
import QRCode from "qrcode";
import { identity, sessionKey, SecureSession } from "./crypto.mjs";
import { readJSON, saveJSON } from "./storage.mjs";
import { CodexRPC } from "./rpc.mjs";
import { DesktopIPC } from "./desktop.mjs";
import { Gateway } from "./gateway.mjs";
export class Bridge {
  constructor({
    relay,
    relayToken,
    stateDir,
    name,
    gateway,
    allowLocal = false,
  }) {
    this.relay = relay.replace(/\/$/, "");
    const u = new URL(this.relay);
    if (
      u.protocol !== "wss:" &&
      !(
        allowLocal &&
        u.protocol === "ws:" &&
        ["localhost", "127.0.0.1", "[::1]"].includes(u.hostname)
      )
    )
      throw new Error("远程连接必须使用 wss://");
    this.token = relayToken;
    this.stateDir = stateDir;
    this.name = name;
    this.gateway = gateway;
    this.peers = new Map();
    this.queues = new Map();
    this.stopping = false;
  }
  async init() {
    this.stateFile = path.join(this.stateDir, "device.json");
    this.device = await readJSON(this.stateFile, null);
    if (!this.device) {
      this.device = { hostId: randomUUID(), key: identity(), trusted: [] };
      await saveJSON(this.stateFile, this.device);
    }
    this.refreshPairing();
  }
  refreshPairing() {
    this.pairToken = randomBytes(32).toString("base64url");
    this.pairExpiry = Date.now() + 120000;
    this.qr = {
      version: 1,
      relay: this.relay,
      hostId: this.device.hostId,
      hostName: this.name,
      hostKey: this.device.key.x,
      pairToken: this.pairToken,
      expires: this.pairExpiry,
    };
  }
  async writePairing() {
    const uri =
      "ifilecodex://pair?data=" +
      encodeURIComponent(
        Buffer.from(JSON.stringify(this.qr)).toString("base64url"),
      );
    const png = await QRCode.toBuffer(uri, { width: 600, margin: 2 });
    await fs.writeFile(path.join(this.stateDir, "pairing.txt"), uri, {
      mode: 0o600,
    });
    await fs.writeFile(path.join(this.stateDir, "pairing.tmp.png"), png, {
      mode: 0o600,
    });
    await fs.rename(
      path.join(this.stateDir, "pairing.tmp.png"),
      path.join(this.stateDir, "pairing.png"),
    );
  }
  async connect() {
    this.challenges = new Map();
    await new Promise((resolve, reject) => {
      const ws = new WebSocket(`${this.relay}/host/${this.device.hostId}`, {
        headers: { Authorization: "Bearer " + this.token },
        maxPayload: 1024 * 1024,
        perMessageDeflate: false,
      });
      this.ws = ws;
      ws.once("open", resolve);
      ws.once("error", reject);
      ws.on("error", () => {});
      ws.on("message", (b) => {
        let m;
        try {
          m = JSON.parse(b);
        } catch {
          return;
        }
        if (m.type === "joined") {
          const nonce = randomBytes(32).toString("base64url");
          this.challenges.set(m.peerId, nonce);
          this.raw(m.peerId, { type: "challenge", nonce });
          return;
        }
        if (m.type === "left") {
          this.gateway.unwatch(m.peerId);
          this.peers.delete(m.peerId);
          this.challenges.delete(m.peerId);
          this.queues.delete(m.peerId);
          return;
        }
        if (m.type !== "data") return;
        const prev = this.queues.get(m.peerId) || Promise.resolve();
        const next = prev
          .then(() => this.incoming(m.peerId, m.data))
          .catch(() => {
            this.raw(m.peerId, {
              type: "rejected",
              message: "连接验证失败，请重新配对",
            });
            this.gateway.unwatch(m.peerId);
            this.peers.delete(m.peerId);
            this.challenges.delete(m.peerId);
          });
        this.queues.set(m.peerId, next);
      });
      ws.on("close", () => {
        for (const id of this.peers.keys()) this.gateway.unwatch(id);
        this.peers.clear();
        if (!this.stopping) {
          this.retry = setTimeout(() => this.connect().catch(() => {}), 3000);
        }
      });
    });
  }
  raw(peerId, data) {
    if (this.ws?.readyState === WebSocket.OPEN)
      this.ws.send(JSON.stringify({ peerId, data }));
  }
  async incoming(id, data) {
    if (data.type === "hello") {
      if (this.peers.has(id)) throw new Error("重复握手");
      if (
        !/^[a-zA-Z0-9_-]{43}$/.test(data.publicKey || "") ||
        !/^[a-zA-Z0-9-]{16,80}$/.test(data.sid || "")
      )
        throw new Error("握手格式无效");
      const challenge = this.challenges.get(id);
      if (!challenge) throw new Error("握手已失效");
      const sessionId = data.sid + "|" + challenge;
      const secure = new SecureSession(
        sessionKey(
          this.device.key,
          data.publicKey,
          this.device.hostId,
          sessionId,
        ),
        this.device.hostId,
        sessionId,
        "h2c",
      );
      const hello = secure.open(data.box);
      const trusted = this.device.trusted.includes(data.publicKey);
      if (!trusted) {
        if (
          !this.pairToken ||
          Date.now() > this.pairExpiry ||
          hello.pairToken !== this.pairToken
        )
          throw new Error("配对码已失效");
        this.pairToken = null;
        this.device.trusted.push(data.publicKey);
        await saveJSON(this.stateFile, this.device);
      }
      const peer = {
        id,
        publicKey: data.publicKey,
        secure,
        emit: (v) => this.raw(id, { type: "secure", box: secure.seal(v) }),
      };
      this.peers.set(id, peer);
      peer.emit({
        event: "ready",
        hostId: this.device.hostId,
        hostName: this.name,
        protocolVersion: 1,
      });
      return;
    }
    const peer = this.peers.get(id);
    if (!peer || data.type !== "secure") throw new Error("需要先握手");
    const m = peer.secure.open(data.box);
    if (
      typeof m.id !== "string" ||
      m.id.length > 80 ||
      typeof m.method !== "string"
    )
      throw new Error("请求格式错误");
    try {
      const result = await this.gateway.handle(m.method, m.params || {}, peer);
      peer.emit({ id: m.id, result });
    } catch (e) {
      peer.emit({ id: m.id, error: String(e.message).slice(0, 500) });
    }
  }
  async close() {
    this.stopping = true;
    clearTimeout(this.retry);
    clearInterval(this.controlTimer);
    for (const id of this.peers.keys()) this.gateway.unwatch(id);
    this.ws?.close();
    await this.gateway.close();
  }
}
if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  const config = JSON.parse(
    await fs.readFile(process.argv[2] || "bridge.config.json", "utf8"),
  );
  const stateDir =
    config.stateDir || path.join(os.homedir(), ".ifileplus-connect");
  const rpc = new CodexRPC(config.codexExecutable || "codex", config.codexHome);
  const ipc = new DesktopIPC(config.ipcSocket);
  await rpc.start();
  await ipc.connect();
  const gateway = new Gateway({
    rpc,
    ipc,
    roots: config.projects,
    stateDir,
    codexHome: config.codexHome,
    desktopCatalog: config.desktopCatalog === true,
  });
  gateway.transcribe = speechClient({ relay: config.relay, token: process.env.IFILE_RELAY_TOKEN });
  await gateway.init();
  const bridge = new Bridge({
    relay: config.relay,
    relayToken: process.env.IFILE_RELAY_TOKEN,
    stateDir,
    name: config.name || os.hostname(),
    gateway,
    allowLocal: config.allowLocal === true,
  });
  await bridge.init();
  await bridge.connect();
  const qrFile = path.join(stateDir, "pairing.png");
  await bridge.writePairing();
  let controlBusy = false;
  bridge.controlTimer = setInterval(async () => {
    if (controlBusy) return;
    controlBusy = true;
    try {
      try {
        await fs.unlink(path.join(stateDir, "pairing-refresh.request"));
        bridge.refreshPairing();
        await bridge.writePairing();
      } catch (e) {
        if (e.code !== "ENOENT") throw e;
      }
      await saveJSON(path.join(stateDir, "connection-status.json"), {
        relayConnected: bridge.ws?.readyState === WebSocket.OPEN,
        trustedPhones: bridge.device.trusted.length,
        connectedPhones: bridge.peers.size,
        updatedAt: Date.now(),
      });
    } catch {
    } finally {
      controlBusy = false;
    }
  }, 1000);
  console.log(`连接已就绪。配对二维码：${qrFile}（2 分钟内有效）`);
  console.log(
    "二维码仅用于首次配对，请勿公开分享。重新启动连接程序可生成新二维码。",
  );
  let closing = false;
  const close = async () => {
    if (closing) return;
    closing = true;
    await bridge.close();
    ipc.close();
    rpc.close();
    process.exit(0);
  };
  process.on("SIGINT", close);
  process.on("SIGTERM", close);
}

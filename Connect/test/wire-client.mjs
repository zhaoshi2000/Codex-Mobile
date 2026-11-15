// A protocol test client; production mobile client lives in the iOS target.
import { WebSocket } from "ws";
import { EventEmitter } from "node:events";
import { randomUUID } from "node:crypto";
import { identity, sessionKey, SecureSession } from "../src/crypto.mjs";
export class WireClient extends EventEmitter {
  constructor(qr) {
    super();
    this.qr = qr;
    this.key = identity();
    this.pending = new Map();
  }
  async connect() {
    await new Promise((resolve, reject) => {
      const ws = new WebSocket(`${this.qr.relay}/phone/${this.qr.hostId}`);
      this.ws = ws;
      const timeout = setTimeout(
        () => reject(Error("handshake timeout")),
        10000,
      );
      ws.on("error", reject);
      ws.on("message", (b) => {
        try {
          const m = JSON.parse(b);
          if (m.type === "challenge") {
            const sid = randomUUID(),
              full = sid + "|" + m.nonce;
            this.secure = new SecureSession(
              sessionKey(this.key, this.qr.hostKey, this.qr.hostId, full),
              this.qr.hostId,
              full,
              "c2h",
            );
            ws.send(
              JSON.stringify({
                type: "hello",
                sid,
                publicKey: this.key.x,
                box: this.secure.seal({ pairToken: this.qr.pairToken }),
              }),
            );
            return;
          }
          if (m.type === "rejected") throw Error("pair rejected");
          const v = this.secure.open(m.box);
          if (v.event === "ready") {
            clearTimeout(timeout);
            resolve();
          } else if (v.id && !v.event) {
            const p = this.pending.get(v.id);
            if (p) {
              clearTimeout(p.timeout);
              this.pending.delete(v.id);
              v.error ? p.reject(Error(v.error)) : p.resolve(v.result);
            }
          } else this.emit("event", v);
        } catch (e) {
          clearTimeout(timeout);
          reject(e);
          this.emit("failure", e);
        }
      });
    });
  }
  request(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = randomUUID(),
        timeout = setTimeout(() => {
          this.pending.delete(id);
          reject(Error("request timeout"));
        }, 45000);
      this.pending.set(id, { resolve, reject, timeout });
      this.ws.send(
        JSON.stringify({
          type: "secure",
          box: this.secure.seal({ id, method, params }),
        }),
      );
    });
  }
  close() {
    for (const p of this.pending.values()) {
      clearTimeout(p.timeout);
      p.reject(Error("closed"));
    }
    this.pending.clear();
    this.ws?.terminate();
  }
}

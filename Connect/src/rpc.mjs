import { spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { createInterface } from "node:readline";
export class CodexRPC extends EventEmitter {
  constructor(exe, home) {
    super();
    this.exe = exe;
    this.home = home;
    this.pending = new Map();
    this.next = 0;
  }
  async start() {
    this.child = spawn(this.exe, ["app-server", "--stdio"], {
      windowsHide: true,
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env, ...(this.home ? { CODEX_HOME: this.home } : {}) },
    });
    this.child.on("error", (e) => this.fail(e));
    this.child.on("exit", () => this.fail(new Error("Codex 连接已关闭")));
    // Never print server stderr: it may include local paths or provider configuration.
    this.child.stderr.on("data", () => {});
    createInterface({ input: this.child.stdout }).on("line", (line) => {
      try {
        const m = JSON.parse(line);
        if (m.id != null && this.pending.has(m.id)) {
          const p = this.pending.get(m.id);
          this.pending.delete(m.id);
          clearTimeout(p.timer);
          m.error ? p.reject(new Error(m.error.message)) : p.resolve(m.result);
        } else this.emit("notification", m);
      } catch {}
    });
    await this.call("initialize", {
      clientInfo: {
        name: "ifileplus-connect",
        title: "iFile+ Connect",
        version: "0.1.0",
      },
      capabilities: { experimentalApi: true },
    });
    this.child.stdin.write(JSON.stringify({ method: "initialized" }) + "\n");
  }
  call(method, params = {}, timeout = 20000) {
    return new Promise((resolve, reject) => {
      const id = ++this.next;
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} 超时`));
      }, timeout);
      this.pending.set(id, { resolve, reject, timer });
      this.child.stdin.write(JSON.stringify({ id, method, params }) + "\n");
    });
  }
  fail(e) {
    for (const p of this.pending.values()) {
      clearTimeout(p.timer);
      p.reject(e);
    }
    this.pending.clear();
  }
  close() {
    this.fail(new Error("连接已关闭"));
    this.child?.stdin.end();
    this.child?.kill();
  }
}

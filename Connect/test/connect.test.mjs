import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { EventEmitter, once } from "node:events";
import { randomUUID, createHash } from "node:crypto";
import http from "node:http";
import { WebSocket, WebSocketServer } from "ws";
import { identity, sessionKey, SecureSession } from "../src/crypto.mjs";
import { createRelay } from "../src/relay.mjs";
import { Bridge } from "../src/bridge.mjs";
import { Gateway } from "../src/gateway.mjs";
import { applyChange, messages } from "../src/timeline.mjs";
import { DesktopCatalog } from "../src/catalog.mjs";

test("bridge replaces a stale host socket when the public phone route reports 503", async (t) => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "ifile-stale-host-"));
  const server = http.createServer();
  const sockets = new WebSocketServer({ noServer: true });
  server.on("upgrade", (request, socket, head) => {
    if (request.url.startsWith("/host/")) sockets.handleUpgrade(request, socket, head, () => {});
    else socket.end("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n");
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  const gateway = { unwatch() {}, async close() {} };
  const bridge = new Bridge({
    relay: `ws://127.0.0.1:${server.address().port}`,
    relayToken: "local-test-token-".repeat(4),
    stateDir: dir,
    name: "Test PC",
    gateway,
    allowLocal: true,
  });
  t.after(async () => {
    await bridge.close();
    for (const socket of sockets.clients) socket.terminate();
    sockets.close();
    await new Promise(resolve => server.close(resolve));
    await fs.rm(dir, { recursive: true, force: true });
  });
  await bridge.init();
  await bridge.connect();
  const stale = bridge.ws;
  await bridge.probeRegistration(stale);
  assert.notEqual(stale.readyState, WebSocket.OPEN);
});

test("authenticated encryption, ordered delivery and fresh-challenge replay protection", () => {
  const a = identity(),
    b = identity(),
    host = randomUUID(),
    sid = randomUUID() + "|challenge1";
  const key = sessionKey(a, b.x, host, sid);
  assert.deepEqual(key, sessionKey(b, a.x, host, sid));
  const c = new SecureSession(key, host, sid, "c2h"),
    h = new SecureSession(key, host, sid, "h2c");
  const box = c.seal({ text: "中文测试" });
  assert.deepEqual(h.open(box), { text: "中文测试" });
  assert.throws(() => h.open(box));
  assert.deepEqual(c.open(h.seal({ ok: true })), { ok: true });
  const fresh = new SecureSession(
    sessionKey(b, a.x, host, "other"),
    host,
    "other",
    "h2c",
  );
  assert.throws(() => fresh.open(box));
  const tampered = c.seal({ secret: true });
  tampered.body = Buffer.alloc(32).toString("base64");
  assert.throws(() => h.open(tampered));
});
test("desktop patches reject missing revisions and prototype mutation", () => {
  const a = applyChange(null, {
    type: "snapshot",
    revision: 1,
    conversationState: { turns: [] },
  });
  const b = applyChange(a, {
    type: "patches",
    baseRevision: 1,
    revision: 2,
    patches: [{ op: "add", path: ["turns", 0], value: { id: "one" } }],
  });
  assert.equal(b.state.turns[0].id, "one");
  assert.equal(a.state.turns.length, 0);
  assert.equal(
    applyChange(a, { type: "patches", baseRevision: 2, patches: [] }),
    null,
  );
  assert.equal(
    applyChange(a, {
      type: "patches",
      baseRevision: 1,
      patches: [{ op: "add", path: ["__proto__", "polluted"], value: true }],
    }),
    null,
  );
  assert.ok(
    Buffer.byteLength(
      JSON.stringify(
        messages(
          Array.from({ length: 100 }, (_, id) => ({
            id,
            items: [{ id, type: "agentMessage", text: "文".repeat(20000) }],
          })),
        ),
      ),
    ) < 256000,
  );
});
test("gateway confines files and deduplicates concurrent/uncertain sends", async (t) => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "ifile-test-"));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const root = path.join(dir, "project");
  await fs.mkdir(root);
  await fs.writeFile(path.join(root, "answer.md"), "# 下载测试\n");
  await fs.writeFile(path.join(dir, "outside"), "private");
  const ipc = new EventEmitter();
  let sends = 0;
  ipc.owner = async () => "desktop";
  ipc.follow = () => {};
  ipc.send = async () => {
    sends++;
    await new Promise((r) => setTimeout(r, 10));
    throw Error("lost acknowledgement");
  };
  const rpc = { call: async () => ({ thread: { cwd: root } }) };
  const g = new Gateway({ rpc, ipc, roots: [root], stateDir: dir });
  await g.init();
  t.after(() => g.close());
  const peer = { id: "p", publicKey: "key" };
  const p = {
    threadId: "thread_1234567",
    messageId: randomUUID(),
    text: "hello",
  };
  const [a, b] = await Promise.all([
    g.handle("send", p, peer),
    g.handle("send", p, peer),
  ]);
  assert.equal(sends, 1);
  assert.equal(a.state, "unknown");
  assert.equal(b.state, "unknown");
  await assert.rejects(g.handle("send", { ...p, text: "different" }, peer));
  await assert.rejects(
    g.handle(
      "filePrepare",
      { projectId: "0", relativePath: "../outside" },
      peer,
    ),
  );
  await fs.symlink(
    dir,
    path.join(root, "escape"),
    process.platform === "win32" ? "junction" : "dir",
  );
  await assert.rejects(
    g.handle(
      "filePrepare",
      { projectId: "0", relativePath: "escape/outside" },
      peer,
    ),
  );
  const lease = await g.handle(
    "filePrepare",
    { projectId: "0", relativePath: "answer.md" },
    peer,
  );
  await assert.rejects(
    g.handle(
      "fileChunk",
      { fileId: lease.id, offset: 0 },
      { publicKey: "other" },
    ),
  );
  const chunk = await g.handle(
    "fileChunk",
    { fileId: lease.id, offset: 0 },
    peer,
  );
  assert.equal(
    createHash("sha256")
      .update(Buffer.from(chunk.data, "base64"))
      .digest("hex"),
    lease.sha256,
  );
  await g.handle("fileRelease", { fileId: lease.id }, peer);
  await assert.rejects(
    g.handle("fileChunk", { fileId: lease.id, offset: 0 }, peer),
  );
});
test("local relay + bridge encrypted pairing, reconnect and one-use invitation", async (t) => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "ifile-wire-test-"));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const token = "local-test-token-".repeat(4);
  const relay = createRelay({ token, port: 0 });
  const port = await relay.start();
  t.after(() => relay.close());
  const gateway = {
    unwatch() {},
    async close() {},
    async handle(method) {
      return { method, value: "PC 文件内容" };
    },
  };
  const bridge = new Bridge({
    relay: `ws://127.0.0.1:${port}`,
    relayToken: token,
    stateDir: dir,
    name: "Test PC",
    gateway,
    allowLocal: true,
  });
  await bridge.init();
  await bridge.connect();
  t.after(() => bridge.close());
  async function phone(key, pairToken) {
    const ws = new WebSocket(
      `ws://127.0.0.1:${port}/phone/${bridge.device.hostId}`,
    );
    t.after(() => ws.terminate());
    const queue = [];
    let waiter;
    ws.on("message", (b) => {
      const m = JSON.parse(b);
      if (waiter) {
        const r = waiter;
        waiter = null;
        r(m);
      } else queue.push(m);
    });
    const next = () =>
      queue.length
        ? Promise.resolve(queue.shift())
        : new Promise((r) => (waiter = r));
    await once(ws, "open");
    const challenge = await next();
    const sid = randomUUID(),
      full = sid + "|" + challenge.nonce;
    const secure = new SecureSession(
      sessionKey(key, bridge.device.key.x, bridge.device.hostId, full),
      bridge.device.hostId,
      full,
      "c2h",
    );
    ws.send(
      JSON.stringify({
        type: "hello",
        sid,
        publicKey: key.x,
        box: secure.seal({ pairToken }),
      }),
    );
    return { ws, next, secure };
  }
  const key = identity(),
    invitation = bridge.qr.pairToken;
  const p = await phone(key, invitation);
  assert.equal(p.secure.open((await p.next()).box).event, "ready");
  bridge.pairExpiry = Date.now() - 1;
  // Expiring the invitation does not invalidate the existing encrypted session.
  p.ws.send(
    JSON.stringify({
      type: "secure",
      box: p.secure.seal({ id: "request1", method: "projects" }),
    }),
  );
  assert.equal(p.secure.open((await p.next()).box).result.value, "PC 文件内容");
  const q = await phone(key, "expired-token");
  assert.equal(q.secure.open((await q.next()).box).event, "ready");
  const stranger = await phone(identity(), invitation);
  assert.equal((await stranger.next()).type, "rejected");
  bridge.refreshPairing();
  p.ws.send(
    JSON.stringify({
      type: "secure",
      box: p.secure.seal({ id: "after-refresh", method: "projects" }),
    }),
  );
  assert.equal(p.secure.open((await p.next()).box).result.value, "PC 文件内容");
});

test("desktop project membership and 10-item pages match local records, not cwd", async (t) => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "ifile-catalog-"));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const assignments = {};
  const rows = Array.from({ length: 25 }, (_, i) => ({
    id: "thread-" + i,
    name: "Chat " + i,
    cwd: dir,
    updatedAt: 100 - i,
    projectId: "app-a",
  }));
  // Two projects share the same folder, but membership must remain distinct.
  for (let i = 0; i < 25; i++)
    assignments["thread-" + i] = {
      projectKind: "local",
      projectId: i % 2 ? "b" : "a",
    };
  await fs.writeFile(
    path.join(dir, ".codex-global-state.json"),
    JSON.stringify({
      "local-projects": {
        a: { id: "a", name: "Project A", rootPaths: [dir] },
        b: { id: "b", name: "Project B", rootPaths: [dir] },
      },
      "project-order": ["a", "b"],
      "thread-project-assignments": assignments,
    }),
  );
  const rpc = {
    async call(method, p) {
      assert.equal(method, "thread/list");
      assert.equal(p.currentAccountOnly, true);
      assert.equal(p.cwd, undefined);
      const start = Number(p.cursor || 0);
      return {
        data: rows.slice(start, start + p.limit),
        nextCursor:
          start + p.limit < rows.length ? String(start + p.limit) : null,
      };
    },
  };
  const c = new DesktopCatalog({ rpc, codexHome: dir });
  const first = await c.threads({});
  assert.equal(first.threads.length, 10);
  assert.equal(first.threads[0].id, "thread-0");
  const more = await c.threads({ cursor: first.nextCursor });
  assert.equal(more.threads[0].id, "thread-10");
  const a = await c.threads({ projectId: "a" });
  assert.equal(a.threads.length, 10);
  assert.ok(a.threads.every((t) => Number(t.id.split("-")[1]) % 2 === 0));
  const last = await c.threads({ projectId: "a", cursor: a.nextCursor });
  assert.equal(last.threads.length, 3);
  assert.equal(last.nextCursor, null);
});
test("large history pages preserve cursor boundaries without skipping messages", async (t) => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "ifile-history-test-"));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const rows = Array.from({ length: 20 }, (_, i) => ({
    turnId: "turn" + i,
    item: { id: "message" + i, type: "agentMessage", text: "文".repeat(16000) },
  }));
  const rpc = {
    async call(method, p) {
      if (method === "thread/read") return { thread: { cwd: dir } };
      const start = Number(p.cursor || 0);
      return {
        data: rows.slice(start, start + p.limit),
        nextCursor:
          start + p.limit < rows.length ? String(start + p.limit) : null,
      };
    },
  };
  const ipc = new EventEmitter();
  ipc.follow = () => {};
  const g = new Gateway({ rpc, ipc, roots: [dir], stateDir: dir });
  await g.init();
  t.after(() => g.close());
  const seen = new Set();
  let cursor;
  do {
    const page = await g.history("thread_history_123", cursor);
    assert.ok(Buffer.byteLength(JSON.stringify(page.messages)) < 230000);
    for (const m of page.messages) {
      assert.ok(!seen.has(m.id));
      seen.add(m.id);
    }
    cursor = page.nextCursor;
  } while (cursor);
  assert.equal(seen.size, 20);
});
test("relay rejects uncredentialed hosts and offline devices", async (t) => {
  const relay = createRelay({
    token: "only-authorized-hosts-".repeat(3),
    port: 0,
  });
  const port = await relay.start();
  t.after(() => relay.close());
  for (const role of ["host", "phone"]) {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/${role}/${randomUUID()}`);
    const [error] = await once(ws, "error");
    assert.match(error.message, role === "host" ? /403/ : /503/);
    ws.terminate();
  }
});

import http from "node:http";
import { WebSocketServer, WebSocket } from "ws";
import { timingSafeEqual } from "node:crypto";
import { pathToFileURL } from "node:url";
export function createRelay({ token, port = 8787, host = "127.0.0.1" }) {
  if (!token || token.length < 32)
    throw new Error("IFILE_RELAY_TOKEN 至少需要 32 个字符");
  const hosts = new Map(),
    peers = new Map(),
    rates = new Map();
  let next = 0;
  const server = http.createServer((req, res) => {
    res.setHeader("Cache-Control", "no-store");
    res.setHeader("Content-Type", "application/json");
    res.writeHead(req.url === "/health" ? 200 : 404);
    res.end(JSON.stringify({ service: "ifileplus-connect", version: 1 }));
  });
  const wss = new WebSocketServer({
    noServer: true,
    maxPayload: 1024 * 1024,
    perMessageDeflate: false,
  });
  const send = (ws, data) => {
    if (ws?.readyState === WebSocket.OPEN) {
      if (ws.bufferedAmount > 4 * 1024 * 1024) {
        ws.close(1013, "slow consumer");
        return;
      }
      ws.send(JSON.stringify(data));
    }
  };
  server.on("upgrade", (req, socket, head) => {
    let u;
    try {
      u = new URL(req.url, "http://localhost");
    } catch {
      socket.destroy();
      return;
    }
    const match = /^\/(host|phone)\/([a-zA-Z0-9-]{16,64})$/.exec(u.pathname);
    const address = req.socket.remoteAddress;
    const now = Date.now();
    let rate = rates.get(address);
    if (!rate || now - rate.at > 60000) rate = { at: now, count: 0 };
    rate.count++;
    rates.set(address, rate);
    if (rates.size > 1000)
      for (const [k, v] of rates) if (now - v.at > 60000) rates.delete(k);
    if (!match || rate.count > 40) {
      socket.end("HTTP/1.1 429 Too Many Requests\r\n\r\n");
      return;
    }
    const [, role, id] = match;
    if (role === "host") {
      const got = Buffer.from(
          (req.headers.authorization || "").replace(/^Bearer /, ""),
        ),
        expected = Buffer.from(token);
      if (
        got.length !== expected.length ||
        !timingSafeEqual(got, expected) ||
        hosts.has(id)
      ) {
        socket.end("HTTP/1.1 403 Forbidden\r\n\r\n");
        return;
      }
    } else if (
      !hosts.has(id) ||
      [...peers.values()].filter((x) => x.hostId === id).length >= 8
    ) {
      socket.end("HTTP/1.1 503 Service Unavailable\r\n\r\n");
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => {
      ws.alive = true;
      ws.on("pong", () => (ws.alive = true));
      ws.on("error", () => {});
      if (role === "host") {
        hosts.set(id, ws);
        ws.on("message", (b) => {
          try {
            const m = JSON.parse(b);
            const p = peers.get(m.peerId);
            if (p?.hostId === id) send(p.ws, m.data);
          } catch {
            ws.close(1007);
          }
        });
        ws.on("close", () => {
          if (hosts.get(id) !== ws) return;
          hosts.delete(id);
          for (const [pid, p] of peers)
            if (p.hostId === id) {
              p.ws.close(1012, "host offline");
              peers.delete(pid);
            }
        });
      } else {
        const peerId = String(++next);
        peers.set(peerId, { hostId: id, ws });
        send(hosts.get(id), { type: "joined", peerId });
        ws.on("message", (b) => {
          try {
            send(hosts.get(id), { type: "data", peerId, data: JSON.parse(b) });
          } catch {
            ws.close(1007);
          }
        });
        ws.on("close", () => {
          peers.delete(peerId);
          send(hosts.get(id), { type: "left", peerId });
        });
      }
    });
  });
  const heartbeat = setInterval(() => {
    for (const ws of wss.clients) {
      if (!ws.alive) {
        ws.terminate();
        continue;
      }
      ws.alive = false;
      ws.ping();
    }
  }, 30000);
  heartbeat.unref();
  return {
    server,
    async start() {
      await new Promise((r) => server.listen(port, host, r));
      return server.address().port;
    },
    async close() {
      clearInterval(heartbeat);
      for (const ws of wss.clients) ws.terminate();
      wss.close();
      await new Promise((r) => server.close(r));
    },
  };
}
if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  const r = createRelay({
    token: process.env.IFILE_RELAY_TOKEN,
    port: Number(process.env.PORT || 8787),
    host: process.env.BIND_HOST || "127.0.0.1",
  });
  await r.start();
  console.log("iFile+ Relay listening");
}

import http from 'node:http';
import { createReadStream } from 'node:fs';
import { randomBytes } from 'node:crypto';

// Bind only to the host's ZeroTier interface. Random, expiring capabilities are
// delivered through the existing authenticated/encrypted phone connection.
export class DirectFiles {
  constructor(leases, addresses) { this.leases = leases; this.addresses = addresses; this.listeners = new Map(); }
  async link(lease) {
    const host = this.addresses()[0];
    if (!host) throw Error('电脑未加入 ZeroTier 网络，请先启动电脑的 ZeroTier');
    let pending = this.listeners.get(host);
    if (!pending) {
      pending = this.listen(host);
      this.listeners.set(host, pending);
      pending.catch(() => this.listeners.delete(host));
    }
    const server = await pending;
    lease.directToken ||= randomBytes(32).toString('hex');
    return { host, port: server.address().port, path: '/' + lease.directToken };
  }
  async listen(host) {
    const server = http.createServer((req, res) => {
      const token = req.url?.slice(1);
      const lease = /^[0-9a-f]{64}$/.test(token || '') && [...this.leases.values()].find(x => x.directToken === token && x.expires > Date.now());
      if (req.method !== 'GET' || !lease) { res.writeHead(404); res.end(); return; }
      res.writeHead(200, {'Content-Type':'application/octet-stream','Content-Length':lease.size,'Cache-Control':'no-store','Connection':'close'});
      const file = createReadStream(lease.file);
      file.on('error', () => res.destroy()); res.on('close', () => file.destroy()); file.pipe(res);
    });
    server.requestTimeout = 30000; server.headersTimeout = 15000;
    server.maxConnections = 8;
    await new Promise((resolve,reject) => { server.once('error',reject);server.listen(0,host,resolve); });
    // Binding failure is reported above; later listener errors cannot crash the bridge.
    server.on('error',()=>{});
    return server;
  }
  async close() { for (const p of this.listeners.values()) { try { const s=await p;s.closeAllConnections();await new Promise(r=>s.close(r)); } catch {} } this.listeners.clear(); }
}

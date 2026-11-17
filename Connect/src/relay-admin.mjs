import fs from 'node:fs/promises';
import path from 'node:path';
import { createHash, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { adminPage } from './relay-admin-page.mjs';

const digest = (value) => createHash('sha256').update(value).digest();
const secureEqual = (left, right) => timingSafeEqual(digest(left), digest(right));
const validWss = (value) => {
  try {
    const url = new URL(value);
    return url.protocol === 'wss:' && !!url.hostname && !url.username && !url.password &&
      !url.search && !url.hash && !url.pathname.match(/\/(host|phone)\//);
  } catch { return false; }
};
const reply = (res, status, data) => {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(data));
};
const readBody = async (req) => {
  let body = '';
  for await (const chunk of req) {
    body += chunk.toString('utf8');
    if (body.length > 4096) throw new Error('请求内容过大');
  }
  return JSON.parse(body || '{}');
};

export function createRelayAdmin({ legacyToken, adminUsername = 'admin', adminPassword, configPath, publicWss = '' }) {
  if (!/^[A-Za-z0-9._-]{1,64}$/.test(adminUsername))
    throw new Error('IFILE_RELAY_ADMIN_USERNAME 需为 1–64 位字母、数字、点、下划线或连字符');
  if (adminPassword && adminPassword.length < 8) throw new Error('IFILE_RELAY_ADMIN_PASSWORD 至少需要 8 个字符');
  if (adminPassword && !configPath) throw new Error('管理后台需要 IFILE_RELAY_CONFIG_PATH 持久化目录');
  if (publicWss && !validWss(publicWss)) throw new Error('IFILE_RELAY_PUBLIC_WSS 必须是有效的 wss:// 地址');
  let state = { version: 1, publicWss, keys: [] };
  let mutation = Promise.resolve();
  const failedLogins = new Map();
  const persist = async () => {
    await fs.mkdir(path.dirname(configPath), { recursive: true });
    const temp = `${configPath}.${process.pid}.${randomUUID()}.tmp`;
    try {
      await fs.writeFile(temp, JSON.stringify(state, null, 2), { mode: 0o600, flag: 'wx' });
      await fs.rename(temp, configPath);
    } finally { await fs.rm(temp, { force: true }); }
  };
  const update = (fn) => {
    const task = mutation.then(async () => {
      const previous = structuredClone(state);
      try { const result = fn(); await persist(); return result; }
      catch (error) { state = previous; throw error; }
    });
    mutation = task.catch(() => {});
    return task;
  };
  const allowed = (token) => {
    if (typeof token !== 'string' || token.length < 32 || token.length > 512) return false;
    if (secureEqual(token, legacyToken)) return true;
    const hash = digest(token);
    return state.keys.some((entry) => /^[a-f0-9]{64}$/.test(entry.hash) && timingSafeEqual(hash, Buffer.from(entry.hash, 'hex')));
  };
  const authenticated = (req) => {
    const header = req.headers.authorization || '';
    if (!header.startsWith('Basic ') || header.length > 2048) return false;
    let credential;
    try { credential = Buffer.from(header.slice(6), 'base64').toString('utf8'); }
    catch { return false; }
    const colon = credential.indexOf(':');
    return colon > -1 && secureEqual(credential.slice(0, colon), adminUsername) &&
      secureEqual(credential.slice(colon + 1), adminPassword);
  };
  const headers = (res) => {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('Content-Security-Policy', "default-src 'none'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'");
  };
  return {
    async init() {
      if (!configPath) return;
      try {
        const loaded = JSON.parse(await fs.readFile(configPath, 'utf8'));
        if (loaded.version !== 1 || !Array.isArray(loaded.keys) || !validWss(loaded.publicWss)) throw new Error('后台配置格式无效');
        if (!loaded.keys.every((entry) => /^[a-f0-9]{64}$/.test(entry.hash) && typeof entry.id === 'string')) throw new Error('后台密钥格式无效');
        state = loaded;
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
        if (adminPassword && !state.publicWss) throw new Error('首次启动管理后台须提供 IFILE_RELAY_PUBLIC_WSS');
        if (adminPassword) await persist();
      }
    },
    allowed,
    async handle(req, res, counts) {
      if (!req.url?.startsWith('/admin')) return false;
      headers(res);
      if (!adminPassword) { reply(res, 404, { error: '管理后台未启用' }); return true; }
      const address = req.socket.remoteAddress || 'unknown';
      const now = Date.now();
      let failures = failedLogins.get(address);
      if (!failures || now - failures.at > 60_000) failures = { at: now, count: 0 };
      if (failures.count >= 30) { reply(res, 429, { error: '登录尝试过多，请稍后重试' }); return true; }
      if (!authenticated(req)) {
        failures.count += 1; failedLogins.set(address, failures);
        if (failedLogins.size > 1000) for (const [ip, value] of failedLogins) if (now - value.at > 60_000) failedLogins.delete(ip);
        res.setHeader('WWW-Authenticate', 'Basic realm="AstroGate Admin", charset="UTF-8"');
        reply(res, 401, { error: '请登录管理后台' }); return true;
      }
      failedLogins.delete(address);
      const pathname = new URL(req.url, 'http://localhost').pathname;
      if ((pathname === '/admin' || pathname === '/admin/') && req.method === 'GET') {
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(adminPage); return true;
      }
      if (pathname === '/admin/api/state' && req.method === 'GET') {
        reply(res, 200, { publicWss: state.publicWss, hosts: counts.hosts, phones: counts.phones,
          keys: state.keys.map(({ id, name, createdAt }) => ({ id, name, createdAt })), legacyKey: true });
        return true;
      }
      if (!['POST', 'DELETE'].includes(req.method) || req.headers['x-astrogate-admin'] !== '1') {
        reply(res, 404, { error: '未找到操作' }); return true;
      }
      const origin = req.headers.origin;
      let validOrigin = true;
      try { validOrigin = !origin || new URL(origin).host === req.headers.host; }
      catch { validOrigin = false; }
      if (!validOrigin) {
        reply(res, 403, { error: '请求来源无效' }); return true;
      }
      try {
        if (pathname === '/admin/api/public-wss' && req.method === 'POST') {
          const { publicWss } = await readBody(req);
          if (typeof publicWss !== 'string' || !validWss(publicWss)) throw new Error('请输入有效的 wss:// 地址');
          await update(() => { state.publicWss = publicWss.replace(/\/$/, ''); });
          reply(res, 200, { publicWss: state.publicWss }); return true;
        }
        if (pathname === '/admin/api/keys' && req.method === 'POST') {
          const body = await readBody(req);
          const name = String(body.name || '').trim();
          const token = body.token === undefined || body.token === '' ? randomBytes(32).toString('base64url') : body.token;
          if (!name || name.length > 50) throw new Error('名称需在 1–50 个字符之间');
          if (typeof token !== 'string' || token.length < 32 || token.length > 512) throw new Error('连接密钥至少需要 32 个字符');
          const created = await update(() => {
            if (allowed(token)) throw new Error('连接密钥已存在');
            if (state.keys.length >= 100) throw new Error('最多保留 100 个连接密钥');
            const entry = { id: randomUUID(), name, hash: digest(token).toString('hex'), createdAt: new Date().toISOString() };
            state.keys.push(entry);
            return { id: entry.id, name, token, createdAt: entry.createdAt };
          });
          reply(res, 201, created); return true;
        }
        const match = /^\/admin\/api\/keys\/([a-f0-9-]{36})$/.exec(pathname);
        if (match && req.method === 'DELETE') {
          if (!state.keys.some((entry) => entry.id === match[1])) { reply(res, 404, { error: '密钥不存在' }); return true; }
          await update(() => { state.keys = state.keys.filter((entry) => entry.id !== match[1]); });
          reply(res, 200, { deleted: true }); return true;
        }
        reply(res, 404, { error: '未找到操作' });
      } catch (error) { reply(res, 400, { error: error.message }); }
      return true;
    },
  };
}

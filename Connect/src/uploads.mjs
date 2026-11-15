import fs from 'node:fs/promises';
import path from 'node:path';
import { randomUUID, createHash } from 'node:crypto';
import { scopedPath, readJSON, saveJSON } from './storage.mjs';

// Only the authenticated phone can use its uploads. The relay never sees file bytes.
export class Uploads {
  constructor(stateDir) { this.dir = path.join(stateDir, 'uploads'); this.active = new Map(); }
  async init() { await fs.mkdir(this.dir, { recursive: true }); this.saved = await readJSON(path.join(this.dir, 'index.json'), {}); }
  async begin(p, peer, root) {
    if (this.active.size >= 6) throw Error('同时最多上传 6 个文件');
    if (!Number.isSafeInteger(p.size) || p.size < 0 || p.size > 25 * 1024 * 1024) throw Error('单个附件上限 25 MB');
    if (typeof p.name !== 'string' || !p.name.trim() || p.name.length > 180 || /[<>:"/\\|?*\x00-\x1f]/.test(p.name) || /[. ]$/.test(p.name) || /^(con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\.|$)/i.test(p.name)) throw Error('附件文件名无效');
    if (!/^[a-f0-9]{64}$/.test(p.sha256 || '')) throw Error('缺少文件校验值');
    const id = randomUUID();
    const file = path.join(this.dir, id + '.part');
    await fs.writeFile(file, '', { flag: 'wx', mode: 0o600 });
    this.active.set(id, { ...p, id, file, root, owner: peer.publicKey, offset: 0, hash: createHash('sha256'), expires: Date.now() + 600000 });
    return { id };
  }
  get(id, peer) { const u = this.active.get(id); if (!u || u.owner !== peer.publicKey || u.expires < Date.now()) throw Error('上传已过期，请重新选择附件'); return u; }
  async chunk(p, peer) {
    const u = this.get(p.id, peer);
    const data = Buffer.from(p.data || '', 'base64');
    if (p.offset !== u.offset || !data.length || data.length > 192 * 1024 || u.offset + data.length > u.size) throw Error('上传分块无效');
    await fs.appendFile(u.file, data); u.hash.update(data); u.offset += data.length; u.expires = Date.now() + 600000;
    return { offset: u.offset };
  }
  async finish(p, peer) {
    const u = this.get(p.id, peer);
    if (u.offset !== u.size) throw Error('附件未传输完成');
    if (u.hash.digest('hex') !== u.sha256) { await this.cancel(p, peer); throw Error('附件完整性校验失败'); }
    const base = path.join(u.root, '.ifile-attachments');
    await fs.mkdir(base, { recursive: true });
    await scopedPath([u.root], base);
    const folder = path.join(base, u.id); await fs.mkdir(folder);
    const target = path.join(folder, u.name); await fs.copyFile(u.file, target, 1);
    const image = /\.(png|jpe?g|gif|webp)$/i.test(u.name);
    this.saved[u.id] = { id: u.id, owner: u.owner, threadId: u.threadId, path: target, name: u.name, image, sha256: u.sha256 };
    await saveJSON(path.join(this.dir, 'index.json'), this.saved);
    await this.cancel(p, peer);
    return { id: u.id, name: u.name, image };
  }
  async resolve(ids, threadId, peer) {
    if (!Array.isArray(ids) || ids.length > 6 || new Set(ids).size !== ids.length) throw Error('附件数量无效');
    return Promise.all(ids.map(async id => {
      const u = this.saved[id];
      if (!u || u.owner !== peer.publicKey || u.threadId !== threadId) throw Error('附件不存在或属于其他会话');
      await fs.access(u.path);
      return u;
    }));
  }
  async cancel(p, peer) { const u = this.active.get(p.id); if (u?.owner === peer.publicKey) { await fs.rm(u.file, { force: true }); this.active.delete(p.id); } return {}; }
  async clean() { for (const u of this.active.values()) if (u.expires < Date.now()) await this.cancel({ id: u.id }, { publicKey: u.owner }); }
  async close() { for (const u of this.active.values()) await this.cancel({ id: u.id }, { publicKey: u.owner }); }
}

// Runtime state is owned by Desktop. A separate read-only app-server reports notLoaded.
// Retain only status summaries, never the transcript snapshots delivered by Desktop.
export class DesktopActivity {
  constructor({ rpc, ipc, catalog, isNeeded = () => false, onCompleted = () => {} }) {
    this.onCompleted = onCompleted; this.completed = new Map(); this.rpc = rpc; this.ipc = ipc; this.catalog = catalog; this.isNeeded = isNeeded;
    this.rows = new Map(); this.followed = new Set(); this.states = new Map();
    this.closed = false; this.lastScan = 0;
    this.listener = m => this.onBroadcast(m); ipc.on('broadcast', this.listener);
    this.closedListener = () => { this.states.clear(); this.lastScan = 0; };
    ipc.on('closed', this.closedListener);
  }
  async list() {
    if (this.ipc.connected === false) throw Error("电脑 Codex 尚未连接，请稍后刷新");
    if (!this.scan && Date.now() - this.lastScan > 15000) {
      this.scan = this.refresh().finally(() => { this.scan = null; });
    }
    if (this.scan) await this.scan;
    return { tasks: [...this.rows.values()].filter(r => this.states.get(r.id)?.status === 'active').map(r => ({ ...r, awaitingApproval: this.states.get(r.id)?.flags?.some(f => ['waitingOnApproval', 'waitingOnUserInput'].includes(f)) || false })), checkedAt: this.lastScan, limited: this.limited || false };
  }
  async refresh() {
    await this.catalog.refresh();
    const found = new Map(); let cursor = null;
    this.limited = false;
    for (let page = 0; page < 50 && !this.closed; page++) {
      const result = await this.rpc.call('thread/list', { limit: 100, currentAccountOnly: true, archived: false, useStateDbOnly: true, sortKey: 'updated_at', ...(cursor ? { cursor } : {}) });
      for (let start = 0; start < result.data.length; start += 8) {
        await Promise.all(result.data.slice(start, start + 8).filter(t => !t.parentThreadId && !t.ephemeral).map(async t => {
          try {
            await this.ipc.owner(t.id);
            if (this.closed) return;
            const pid = this.catalog.projectFor(t);
            const row = { id: t.id, title: (t.name || t.preview || '未命名对话').slice(0, 120), projectId: pid, projectName: this.catalog.projects.find(p => p.id === pid)?.name || '未分组' };
            found.set(t.id, row); this.rows.set(t.id, row);
            if (!this.followed.has(t.id)) { this.followed.add(t.id); this.ipc.follow(t.id); }
          } catch { /* No Desktop owner means this is not an active Desktop task. */ }
        }));
      }
      cursor = result.nextCursor || null;
      if (!cursor) break;
      if (page === 49) this.limited = true;
    }
    if (this.closed) return;
    for (const id of this.followed) if (!found.has(id)) {
      this.followed.delete(id); this.rows.delete(id); this.states.delete(id);
      if (!this.isNeeded(id)) { try { this.ipc.follow(id, false); } catch {} }
    }
    // Initial follow snapshots are asynchronous; ordinary updates use the retained status.
    await new Promise(r => setTimeout(r, 250)); this.lastScan = Date.now();
  }
  onBroadcast(m) {
    if (m.method !== 'thread-stream-state-changed' || m.version !== 13) return;
    const id = m.params?.conversationId; if (!this.followed.has(id)) return;
    const before = this.states.get(id)?.status;
    const c = m.params.change;
    if (c?.type === 'snapshot') {
      const runtime = c.conversationState?.threadRuntimeStatus;
      this.states.set(id, { revision: c.revision, status: runtime?.type, flags: runtime?.activeFlags || [] });
    } else if (c?.type === 'patches') {
      const state = this.states.get(id);
      if (!state || state.revision !== c.baseRevision) { this.states.delete(id); this.ipc.follow(id); return; }
      for (const p of c.patches || []) {
        if (!Array.isArray(p.path) || p.path[0] !== 'threadRuntimeStatus') continue;
        if (p.path.length === 1) { state.status = p.value?.type; state.flags = p.value?.activeFlags || []; }
        if (p.path[1] === 'type') state.status = p.op === 'remove' ? undefined : p.value;
        if (p.path[1] === 'activeFlags') {
          if (p.path.length === 2) state.flags = Array.isArray(p.value) ? p.value : [];
          else { const i = Number(p.path[2]); if (Number.isInteger(i) && i >= 0 && i < 20) { if (p.op === 'remove') state.flags.splice(i, 1); else state.flags[i] = p.value; } }
        }
      }
      state.revision = c.revision;
    }
    if (before === 'active' && this.states.get(id)?.status === 'idle') {
      const at = Date.now(); this.completed.set(id, at); this.onCompleted(id, at);
    }
  }
  close() {
    this.closed = true; this.ipc.off('broadcast', this.listener); this.ipc.off('closed', this.closedListener);
    for (const id of this.followed) if (!this.isNeeded(id)) { try { this.ipc.follow(id, false); } catch {} }
    this.followed.clear(); this.states.clear(); this.rows.clear();
  }
}

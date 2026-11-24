import { CodexRPC } from "./rpc.mjs";
import { NetworkTunnels } from "./network-tunnels.mjs";
import { DirectFiles } from "./direct-files.mjs";
import { quotaSummary } from "./quota.mjs";
import { localLinkPath, matchesLinkedFile } from "./download-access.mjs";
import { questionGroups, questionAnswer } from "./questions.mjs";
import fs from "node:fs/promises";
import { createReadStream } from "node:fs";
import path from "node:path";
import os from "node:os";
import { createHash, randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { scopedPath, saveJSON, readJSON } from "./storage.mjs";
import { messages, applyChange, desktopTurns, progress, turnOutcome } from "./timeline.mjs";
import { Uploads } from "./uploads.mjs";
import { DesktopActivity } from "./activity.mjs";
import { DesktopCatalog } from "./catalog.mjs";

const summaryCursorPrefix = "summary:";
export class Gateway {
  constructor({
    rpc,
    ipc,
    roots = [],
    stateDir,
    codexHome,
    desktopCatalog = false,
  }) {
    this.rpc = rpc;
    this.networkTunnels = new NetworkTunnels();
    this.ipc = ipc;
    this.rootPaths = roots;
    this.stateDir = stateDir;
    this.codexHome = codexHome;
    this.queued = new Map();
    this.thumbnails = new Map();
    this.leases = new Map();
    this.directFiles = new DirectFiles(this.leases, () => this.networkTunnels.addresses());
    this.uploads = new Uploads(stateDir);
    this.monitors = new Map();
    this.pendingQueued = new Map();
    this.subscribers = new Map();
    this.states = new Map();
    this.timers = new Map();
    this.historyReads = new Map();
    this.historyCache = new Map();
    this.historyBudgetMs = 7000;
    this.historyRefreshNeeded = new Set();
    if (desktopCatalog) {
      this.catalog = new DesktopCatalog({ rpc, codexHome });
      this.activity = new DesktopActivity({ rpc, ipc, catalog: this.catalog, onCompleted: (id, at) => { this.completedThreads[id] = at; this.completedThreadProjects[id] = this.activity.rows.get(id)?.projectId || null; this.saveNavigation().catch(() => {}); }, isNeeded: id => this.pendingQueued.has(id) || this.monitors.has(id) || [...this.subscribers.values()].some(s => s.threadId === id) });
    }
  }
  async init() {
    await this.uploads.init();
    this.roots = await Promise.all(this.rootPaths.map((p) => fs.realpath(p)));
    this.projects = this.roots.map((root, i) => ({
      id: String(i),
      name: path.basename(root),
      path: root,
    }));
    this.ledger = await readJSON(
      path.join(this.stateDir, "operations.json"),
      {},
    );
    for (const [id, record] of Object.entries(this.ledger)) {
      if (record.mode === "queued" && !record.queueAction && !record.completedAt && Date.now() - record.at < 86400000) {
        if (!this.pendingQueued.has(record.threadId)) this.pendingQueued.set(record.threadId, new Set());
        this.pendingQueued.get(record.threadId).add(id);
      }
    }
    this.navigation = await readJSON(path.join(this.stateDir, "navigation.json"), { peers: {}, completed: {} });
    this.completedThreads = this.navigation.completed;
    this.completedThreadProjects = this.navigation.projects ||= {};
    this.ipc.on("broadcast", (m) => this.onBroadcast(m));
    this.ipc.on("closed", () => {
      this.states.clear();
      this.queued.clear();
      this.historyRefreshNeeded.clear();
      for (const timer of this.timers.values()) clearTimeout(timer);
      this.timers.clear();
      const status = this.desktopStatus();
      for (const { threadId, peer } of this.subscribers.values()) {
        // Older phones still need a notice to disable sending.
        peer.emit?.({ event: "notice", message: "电脑通道重连中，请等待状态恢复" });
        peer.emit?.({ event: "desktopStatus", threadId, ...status });
      }
    });
    this.ipc.on("connected", () => {
      for (const { threadId, peer } of this.subscribers.values()) {
        peer.emit?.({ event: "desktopStatus", threadId, desktopState: "ready" });
      }
    });
    for (const id of this.pendingQueued.keys()) this.ipc.follow(id);
    this.leaseTimer = setInterval(
      () => this.cleanLeases().catch(() => {}),
      60000,
    );
    this.leaseTimer.unref();
  }
  desktopStatus() {
    if (this.ipc.connected !== false) return { desktopState: "ready" };
    if (this.ipc.errorCode === "ENOENT") {
      return { desktopState: "unavailable", message: "电脑 Codex 的通信入口未就绪。可先查看历史，发送将在连接恢复后可用。" };
    }
    return { desktopState: "reconnecting", message: "正在恢复电脑 Codex 连接。可先查看历史。" };
  }
  async authorizeThread(id) {
    if (typeof id !== "string" || !/^[a-zA-Z0-9_-]{10,100}$/.test(id))
      throw new Error("无效会话");
    const { thread } = await this.rpc.call("thread/read", { threadId: id });
    if (!this.catalog) await scopedPath(this.roots, thread.cwd);
    return thread;
  }
  project(id) {
    const p = this.projects.find((x) => x.id === id);
    if (!p) throw new Error("无效项目");
    return p;
  }
  async fileScope(id, relativePath = "") {
    if (!this.catalog) return { ...this.project(id), relativePath, prefix: "" };
    if (id.startsWith("thread:")) {
      const t = await this.authorizeThread(id.slice(7));
      return { path: await fs.realpath(t.cwd), relativePath, prefix: "" };
    }
    const projects = await this.catalog.refresh();
    const p = projects.find((x) => x.id === id);
    if (!p) throw new Error("项目已移除，请刷新");
    if (!relativePath) return { virtualRoots: p.roots };
    const normalized = relativePath.replaceAll("\\", "/");
    const [slot, ...rest] = normalized.split("/");
    if (!/^@\d+$/.test(slot) || !p.roots[Number(slot.slice(1))])
      throw new Error("无效项目目录");
    return {
      path: await fs.realpath(p.roots[Number(slot.slice(1))]),
      relativePath: rest.join("/"),
      prefix: slot + "/",
    };
  }
  async history(threadId, cursor) {
    await this.authorizeThread(threadId);
    const key = JSON.stringify([threadId, cursor || null]);
    const cached = this.historyCache.get(key);
    if (cached && cached.desktopConnected === this.ipc.connected && Date.now() - cached.at < 2000) return cached.page;
    if (this.historyReads.has(key)) return this.historyReads.get(key);
    const work = this.readHistoryPage(threadId, cursor).then(page => {
      this.historyCache.set(key, {at: Date.now(), desktopConnected: this.ipc.connected, page});
      while (this.historyCache.size > 8) this.historyCache.delete(this.historyCache.keys().next().value);
      return page;
    }).finally(() => this.historyReads.delete(key));
    this.historyReads.set(key, work);
    return work;
  }
  async readHistoryPage(threadId, cursor) {
    if (typeof cursor === "string" && cursor.startsWith(summaryCursorPrefix)) {
      return this.readHistorySummary(threadId, cursor.slice(summaryCursorPrefix.length));
    }
    if (!cursor && this.ipc.connected === false) {
      try { return await this.readHistorySummary(threadId); }
      catch { /* Older app servers can still provide the item history. */ }
    }
    return this.readHistory(threadId, cursor);
  }

  async readHistorySummary(threadId, cursor) {
    // While the live stream is unavailable, load visible turns in one disk scan.
    // The summary retains messages and excludes large internal tool outputs.
    for (let limit = 16; ; limit = Math.max(1, Math.floor(limit / 2))) {
      const page = await this.rpc.call("thread/turns/list", {
        threadId, limit, sortDirection: "desc", itemsView: "summary",
        ...(cursor ? { cursor } : {}),
      }, 15000);
      const turns = page.data.slice().reverse();
      const rows = messages(turns, Infinity, false, Infinity);
      const fits = Buffer.byteLength(JSON.stringify(rows)) <= 230000;
      if (limit > 1 && !fits) continue;
      return {
        messages: fits ? rows : messages(turns),
        nextCursor: page.nextCursor ? summaryCursorPrefix + page.nextCursor : null,
      };
    }
  }

  async readHistory(threadId, cursor) {
    const deadline = Date.now() + this.historyBudgetMs;
    let limit = cursor ? 50 : 15, result = [], next = cursor || null, pagesRead = 0;
    // Item pages include tools and reasoning. Fill a page with visible chat
    // messages, not the first 50 internal records. Never forward tool outputs.
    for (let scans = 0; scans < 100; scans++) {
      // Tool-heavy histories can require many expensive disk scans. Return a
      // partial page before the phone times out, preserving the next cursor.
      if (scans && Date.now() >= deadline) break;
      let r;
      try { r = await this.rpc.call("thread/items/list", {
        threadId,
        limit,
        sortDirection: "desc",
        ...(next ? { cursor: next } : {}),
      }, pagesRead ? Math.max(1000, deadline - Date.now()) : 8000); }
      catch (error) { if (!pagesRead) throw error; break; }
      pagesRead++;
      const page = messages(
        r.data
          .slice()
          .reverse()
          .map((x) => ({ id: x.turnId, items: [{ ...x.item, startedAtMs: x.startedAtMs ?? x.item.startedAtMs, completedAtMs: x.completedAtMs ?? x.item.completedAtMs }] })),
        Infinity,
        true,
      );
      let toolCount = 0;
      const combined = [...page, ...result].reverse().filter(m => m.role !== "tool" || ++toolCount <= 100).reverse();
      if (Buffer.byteLength(JSON.stringify(combined)) >= 230000) {
        if (limit === 1) break;
        limit = Math.max(1, Math.floor(limit / 2));
        continue; // Retry the same cursor so no message is skipped.
      }
      result = combined;
      const previous = next;
      next = r.nextCursor || null;
      const chatCount = result.filter(m => m.role !== "tool").length;
      if (!next || next === previous || chatCount >= 50) break;
      limit = Math.min(50, 50 - chatCount);
    }
    let outcome;
    // Persisted item pages omit terminal errors; they live on the turn itself.
    // Fetch bounded turn metadata until the oldest visible turn, not the entire thread.
    try {
      const metadata = [], oldest = result[0]?.turnId;
      let turnCursor;
      const metadataDeadline = Date.now() + 3000;
      for (let page = 0; page < 3; page++) {
        if (Date.now() >= metadataDeadline) break;
        const r = await this.rpc.call("thread/turns/list", {threadId, limit: 100, sortDirection: "desc", itemsView: "notLoaded", ...(turnCursor ? {cursor: turnCursor} : {})}, Math.max(1, metadataDeadline - Date.now()));
        metadata.push(...(r.data || []));
        if (!oldest || metadata.some(t => (t.id || t.turnId) === oldest) || !r.nextCursor || r.nextCursor === turnCursor) break;
        turnCursor = r.nextCursor;
      }
      if (!cursor) outcome = turnOutcome(metadata[0]);
      const oldestIndex = metadata.findIndex(t => (t.id || t.turnId) === oldest);
      const visible = new Set(result.map(m => m.turnId));
      for (let index = Math.min(oldestIndex < 0 ? metadata.length - 1 : oldestIndex, metadata.length - 1); index >= 0; index--) {
        const turn = metadata[index], id = turn.id || turn.turnId;
        if (turn.status !== "failed" || (!visible.has(id) && (cursor || oldestIndex < 0))) continue;
        const row = messages([{id, status: turn.status, error: turn.error, items: []}])[0];
        if (!row || result.some(m => m.id === row.id)) continue;
        const end = result.findLastIndex(m => m.turnId === id);
        if (end >= 0) result.splice(end + 1, 0, row);
        else {
          const newer = new Set(metadata.slice(0, index).map(t => t.id || t.turnId));
          const nextIndex = result.findIndex(m => newer.has(m.turnId));
          result.splice(nextIndex < 0 ? result.length : nextIndex, 0, row);
        }
      }
    } catch {}
    // One stable error row per turn, even when the same error occurs in several item pages.
    const seen = new Set();
    result = result.slice().reverse().filter(m => { if (seen.has(m.id)) return false; seen.add(m.id); return true; }).reverse();
    while (result.length && Buffer.byteLength(JSON.stringify(result)) > 230000) result.shift();
    // History remains readable during IPC loss, but is not proof of current runtime state.
    return { messages: result, nextCursor: next, ...(outcome && this.ipc.connected !== false ? {outcome} : {}) };
  }
  async downloadPath(p, project) {
    const requested = p.absolutePath ? localLinkPath(p.absolutePath) : path.resolve(project.path, project.relativePath || "");
    if (!requested) throw Error("无效文件路径");
    try { return await scopedPath([project.path], requested); } catch (error) {
      if (!p.absolutePath || !this.catalog || !p.projectId.startsWith("thread:")) throw error;
    }
    const threadId = p.projectId.slice(7);
    const live = desktopTurns(this.states.get(threadId)?.state).flatMap(t => [...(t.items || []), ...(t.params?.input ? [{ type: "userMessage", content: t.params.input }] : [])]);
    let real = await matchesLinkedFile(requested, live);
    if (real) return real;
    let cursor;
    for (let page = 0; page < 30; page++) {
      const result = await this.rpc.call("thread/items/list", { threadId, limit: 100, sortDirection: "desc", ...(cursor ? { cursor } : {}) });
      real = await matchesLinkedFile(requested, result.data.map(x => x.item));
      if (real) return real;
      cursor = result.nextCursor;
      if (!cursor) break;
    }
    throw Error("此文件不在对话目录，也不是此对话中 Codex 提供的文件链接；请让 Codex 重新提供下载链接");
  }
  async createThread(p, peer) {
    if (!this.catalog) throw Error("请启用电脑本机目录模式");
    if (!/^[a-zA-Z0-9-]{16,80}$/.test(p.requestId || "")) throw Error("创建请求 ID 无效");
    const title = typeof p.title === "string" ? p.title.trim().slice(0, 120) : "";
    const digest = createHash("sha256").update(JSON.stringify([p.projectId || null, title])).digest("hex");
    const key = "create:" + p.requestId;
    let record = this.ledger[key];
    if (record) {
      if (record.digest !== digest || record.owner !== peer.publicKey) throw Error("创建请求 ID 冲突");
      if (record.result) return record.result;
      if (!record.threadId) throw Error("创建结果待核实，请先刷新电脑对话列表，避免重复创建");
    } else {
      if (Object.keys(this.ledger).length >= 10000) throw Error("操作记录已满");
      await this.catalog.refresh();
      let cwd, projectId = null;
      if (p.projectId) {
        const project = this.catalog.projects.find(x => x.id === p.projectId);
        if (!project?.roots?.length) throw Error("项目没有本地目录，请在电脑配置后重试");
        projectId = [...this.catalog.appToLocal].find(([, local]) => local === p.projectId)?.[0];
        if (!projectId) throw Error("项目尚未同步到 Codex，请先在电脑打开此项目");
        const server = await this.rpc.call("project/read", { projectId });
        if (!server.project) throw Error("电脑项目已移除，请刷新");
        cwd = await fs.realpath(project.roots[0]);
      } else {
        cwd = path.join(this.stateDir, "conversations", p.requestId);
        await fs.mkdir(cwd, { recursive: true });
      }
      record = { digest, owner: peer.publicKey, state: "unknown", at: Date.now() };
      this.ledger[key] = record; await this.saveLedger();
      // thread/unsubscribe does not release the process's writer lock. Use a short-lived
      // creator, then close it so Desktop can resume and own the original conversation.
      const creator = this.rpc.exe ? new CodexRPC(this.rpc.exe, this.rpc.home) : this.rpc;
      try {
        if (creator !== this.rpc) await creator.start();
        const result = await creator.call("thread/start", { cwd, projectId });
        record.threadId = result.thread.id; await this.saveLedger();
        await creator.call("thread/name/set", { threadId: record.threadId, name: title || "新对话" });
      } finally { if (creator !== this.rpc) creator.close(); }
    }
    const id = record.threadId;
    await this.rpc.call("thread/name/set", { threadId: id, name: title || "新对话" });
    await this.rpc.call("thread/unsubscribe", { threadId: id });
    record.result = { thread: { id, title: title || "新对话" } }; record.state = "accepted";
    await this.saveLedger(); this.catalog.pages.clear();
    if (this.activity) this.activity.lastScan = 0;
    return record.result;
  }
  async deleteThread(p, peer) {
    if (p.confirm !== true) throw Error("请确认同时永久删除电脑上的原对话");
    if (!/^[a-zA-Z0-9-]{16,80}$/.test(p.requestId || "")) throw Error("删除请求 ID 无效");
    const key = "delete:" + p.requestId;
    const previous = this.ledger[key];
    if (previous) {
      if (previous.owner !== peer.publicKey || previous.threadId !== p.threadId) throw Error("删除请求 ID 冲突");
      if (previous.state === "accepted") return { deleted: true };
      throw Error("删除结果待核实，请刷新电脑列表后检查");
    }
    await this.authorizeThread(p.threadId);
    let owned = false;
    if (this.ipc.connected) { try { await this.ipc.owner(p.threadId); owned = true; } catch {} }
    if (owned) {
      // Ask the owner for a fresh snapshot before any destructive action.
      const runtime = await new Promise((resolve, reject) => {
        const timer = setTimeout(() => { this.ipc.off("broadcast", listener); reject(Error("无法确认对话是否正在运行，请稍后重试")); }, 4000);
        const listener = m => { if (m.method === "thread-stream-state-changed" && m.version === 13 && m.params?.conversationId === p.threadId && m.params.change?.type === "snapshot") { clearTimeout(timer); this.ipc.off("broadcast", listener); resolve(m.params.change.conversationState); } };
        this.ipc.on("broadcast", listener); this.ipc.follow(p.threadId);
      });
      if (runtime.threadRuntimeStatus?.type !== "idle" || (runtime.requests || []).some(r => !r.completed)) throw Error("对话正在运行或等待确认，请结束任务后再删除");
    }
    if (Object.keys(this.ledger).length >= 10000) throw Error("操作记录已满");
    const record = { owner: peer.publicKey, threadId: p.threadId, state: "unknown", at: Date.now() };
    this.ledger[key] = record; await this.saveLedger();
    try { await this.rpc.call("thread/delete", { threadId: p.threadId }, 35000); }
    catch (error) {
      if (/already has an active writer/i.test(error.message)) {
        // This is an explicit refusal, not an uncertain delivery. Retrying is safe.
        delete this.ledger[key]; await this.saveLedger();
        throw Error("电脑 Codex 仍占用此对话，请先在电脑关闭该对话后再删除。若仍被占用，可在任务结束后退出并重新打开 Codex 再试；原记录未删除。");
      }
      throw error;
    }
    record.state = "accepted"; await this.saveLedger();
    this.catalog?.pages.clear();
    this.states.delete(p.threadId); this.monitors.delete(p.threadId);
    try { this.ipc.follow(p.threadId, false); } catch {}
    for (const [id, sub] of this.subscribers) if (sub.threadId === p.threadId) { sub.peer.emit?.({ event: "notice", message: "此对话已删除" }); this.unwatch(id); }
    if (this.activity) { this.activity.lastScan = 0; this.activity.rows.delete(p.threadId); this.activity.states.delete(p.threadId); }
    return { deleted: true };
  }
  async handle(method, p, peer) {
    if (method === "filePrepare" || method === "imageThumbnail" || method.startsWith("upload")) {
      const run = (this.fileQueue || Promise.resolve()).then(() =>
        this.dispatch(method, p, peer),
      );
      this.fileQueue = run.catch(() => {});
      return run;
    }
    if (["send", "steerQueued", "removeQueued", "answer", "answerStatus", "createThread", "deleteThread", "renameThread", "forkThread", "setModel", "pinThread", "markRead"].includes(method)) {
      const run = (this.sendQueue || Promise.resolve()).then(() =>
        this.dispatch(method, p, peer),
      );
      this.sendQueue = run.catch(() => {});
      return run;
    }
    return this.dispatch(method, p, peer);
  }
  async dispatch(method, p, peer) {
    switch (method) {
      case "networkInfo": return { zeroTierAddresses: this.networkTunnels.addresses() };
      case "networkOpen": return this.networkTunnels.open(peer.publicKey, p.host, p.port);
      case "networkRead": return this.networkTunnels.read(peer.publicKey, p.id);
      case "networkWrite": return this.networkTunnels.write(peer.publicKey, p.id, p.data);
      case "networkClose": this.networkTunnels.session(peer.publicKey, p.id); this.networkTunnels.drop(p.id); return {};
      case "transcribe": {
        if (!this.transcribe) throw Error("请更新电脑连接程序以启用语音输入");
        return this.transcribe(p);
      }
      case "quota": {
        try { return quotaSummary(await this.rpc.call("account/rateLimits/read", {}, 15000)); }
        catch { return {available: false, windows: [], message: "暂时无法读取 Codex 额度，请确认电脑已登录 Codex，或稍后刷新。"}; }
      }
      case "navigation": return this.navigationData(peer);
      case "markRead": {
        await this.authorizeThread(p.threadId);
        this.peerNavigation(peer).read[p.threadId] = Date.now(); await this.saveNavigation(); return {};
      }
      case "pinThread": {
        await this.authorizeThread(p.threadId);
        if (typeof p.pinned !== "boolean") throw Error("无效置顶状态");
        this.peerNavigation(peer).pins[p.threadId] = p.pinned;
        await this.saveNavigation(); return this.navigationData(peer);
      }
      case "models": {
        await this.authorizeThread(p.threadId);
        const current = await this.ipc.modelSettings(p.threadId);
        const list = await this.rpc.call("model/list", { limit: 100, ...(current.modelProvider ? { modelProvider: current.modelProvider } : {}) });
        return { current, models: list.data.map(m => ({ id: m.model, name: m.displayName || m.model, efforts: m.supportedReasoningEfforts || [], defaultEffort: m.defaultReasoningEffort })) };
      }
      case "setModel": {
        await this.authorizeThread(p.threadId);
        const data = await this.dispatch("models", { threadId: p.threadId }, peer);
        const model = data.models.find(m => m.id === p.model);
        if (!model) throw Error("此模型不在电脑当前提供商的列表中");
        if (p.effort !== undefined && !model.efforts.some(e => e.reasoningEffort === p.effort)) throw Error("当前模型不支持此推理强度，请刷新模型列表");
        const effort = p.effort ?? (model.efforts.some(e => e.reasoningEffort === data.current.reasoningEffort) ? data.current.reasoningEffort : model.defaultEffort);
        return { current: await this.ipc.setModel(p.threadId, model.id, effort) };
      }
      case "forkThread": return this.forkThread(p, peer);
      case "createThread": return this.createThread(p, peer);
      case "deleteThread": return this.deleteThread(p, peer);
      case "renameThread": {
        await this.authorizeThread(p.threadId);
        const name = typeof p.title === "string" ? p.title.trim() : "";
        if (!name || name.length > 120 || /[\x00-\x1f\x7f]/.test(name)) throw Error("对话名称须为 1–120 个字符，不能包含换行");
        await this.rpc.call("thread/name/set", { threadId: p.threadId, name });
        this.catalog?.pages.clear();
        for (const sub of this.subscribers.values()) sub.peer.emit?.({ event: "threadRenamed", threadId: p.threadId, title: name });
        return { title: name };
      }
      case "uploadBegin": {
        const thread = await this.authorizeThread(p.threadId);
        return this.uploads.begin(p, peer, await fs.realpath(thread.cwd));
      }
      case "uploadChunk": return this.uploads.chunk(p, peer);
      case "uploadFinish": return this.uploads.finish(p, peer);
      case "uploadCancel": return this.uploads.cancel(p, peer);
      case "completions": return { items: Object.entries(this.ledger).filter(([id, r]) => r.owner === peer.publicKey && r.completedAt && r.completedAt > Date.now() - 86400000).slice(-100).map(([id, r]) => ({ id, threadId: r.threadId, at: r.completedAt, outcome: r.outcome || null })) };
      case "activity":
        if (!this.activity) throw new Error("请启用电脑本机目录模式");
        return { ...await this.activity.list(), ...this.badges(peer) };
      case "ping":
        return { alive: true };
      case "projects":
        return {
          projects: this.catalog ? await this.catalog.refresh() : this.projects,
        };
      case "threads": {
        if (this.catalog) return this.catalog.threads(p);
        const project = this.project(p.projectId);
        const r = await this.rpc.call("thread/list", {
          cwd: project.path,
          limit: 10,
          sortKey: "updated_at",
          sourceKinds: ["cli", "vscode", "appServer", "unknown"],
          useStateDbOnly: true,
          ...(p.cursor ? { cursor: p.cursor } : {}),
        });
        return {
          threads: r.data.map((t) => ({
            id: t.id,
            title: (t.name || t.preview || "未命名对话").slice(0, 120),
            updatedAt: t.updatedAt,
            cwd: t.cwd,
          })),
          nextCursor: r.nextCursor || null,
        };
      }
      case "history":
        return this.history(p.threadId, p.cursor);
      case "commandDetails": {
        await this.authorizeThread(p.threadId);
        if (typeof p.turnId !== "string" || typeof p.itemId !== "string" || p.turnId.length > 150 || p.itemId.length > 200) throw Error("无效命令记录");
        let item = desktopTurns(this.states.get(p.threadId)?.state).find(t => (t.id || t.turnId) === p.turnId)?.items?.find(i => i.id === p.itemId);
        if (!item) {
          const r = await this.rpc.call("thread/items/read", { threadId: p.threadId, turnId: p.turnId, itemIds: [p.itemId] });
          item = r.data?.find(x => x.item?.id === p.itemId)?.item;
        }
        if (item?.type !== "commandExecution") throw Error("命令记录暂不可用，请稍后重试");
        const output = String(item.aggregatedOutput || "");
        return { command: String(item.command || "").slice(0, 16000), output: output.slice(-32000), truncated: output.length > 32000,
          cwd: String(item.cwd || ""), status: item.status || "unknown", exitCode: item.exitCode ?? null };
      }
      case "watch": {
        await this.authorizeThread(p.threadId);
        if (this.subscribers.get(peer.id)?.threadId !== p.threadId) {
          this.unwatch(peer.id);
          this.subscribers.set(peer.id, { threadId: p.threadId, peer });
        }
        this.ipc.follow(p.threadId);
        const status = this.desktopStatus();
        if (status.desktopState !== "ready") return { writable: false, ...status };
        let writable = false;
        try {
          await this.ipc.owner(p.threadId);
          writable = true;
        } catch (error) {
          if (error.code === "DESKTOP_READ_TIMEOUT") {
            return { writable: false, desktopState: "reconnecting", message: "电脑 Codex 状态查询超时，正在重试。可先查看历史。" };
          }
        }
        const current = this.desktopStatus();
        if (current.desktopState !== "ready") return { writable: false, ...current };
        return {
          writable,
          ...current,
          message: writable
            ? "已连接桌面原会话"
            : "请在电脑打开此对话，或点击“在电脑打开”",
        };
      }
      case "unwatch":
        if (!p.threadId || this.subscribers.get(peer.id)?.threadId === p.threadId) this.unwatch(peer.id);
        return {};
      case "activate": {
        await this.authorizeThread(p.threadId);
        if (!/^[a-f0-9-]{36}$/i.test(p.threadId))
          throw new Error("无法打开此会话");
        const uri = "codex://threads/" + p.threadId + "?hostId=local";
        let cmd =
          process.platform === "win32"
            ? "explorer.exe"
            : process.platform === "darwin"
              ? "open"
              : "xdg-open";
        let args = [uri];
        if (process.platform === "win32" && this.rpc.exe) {
          const desktop = path.resolve(path.dirname(this.rpc.exe), "..", "ChatGPT.exe");
          try { await fs.access(desktop); cmd = desktop; args = ["--single-argument", uri]; } catch {}
        }
        const child = spawn(cmd, args, { windowsHide: true, stdio: "ignore" });
        child.on("error", () => {});
        child.unref();
        return { message: "已请求电脑打开对话，请稍后重新连接" };
      }
      case "answerStatus": {
        await this.authorizeThread(p.threadId);
        const record = this.ledger[p.messageId];
        if (!record) return { state: "notSubmitted" };
        if (record.owner !== peer.publicKey || record.threadId !== p.threadId || record.groupId !== p.groupId) throw Error("无权查询此回答");
        return { state: record.state };
      }
      case "answer": {
        await this.authorizeThread(p.threadId);
        if (this.subscribers.get(peer.id)?.threadId !== p.threadId) throw Error("请先打开原对话");
        if (!/^[a-zA-Z0-9-]{16,80}$/.test(p.messageId || "")) throw Error("消息 ID 无效");
        const digest = createHash("sha256").update(JSON.stringify([p.threadId, p.groupId, p.answers])).digest("hex");
        const old = this.ledger[p.messageId];
        if (old) { if (old.digest !== digest || old.owner !== peer.publicKey) throw Error("答案 ID 冲突"); return old; }
        if (Object.values(this.ledger).some(r => r.threadId === p.threadId && r.groupId === p.groupId)) throw Error("此问题已有提交记录，请核实电脑上的回答，不要重复发送");
        const state = this.states.get(p.threadId)?.state;
        if (!state || !this.ipc.connected) throw Error("请重新连接后核实问题");
        const group = questionGroups(state, desktopTurns(state)).find(g => g.id === p.groupId);
        if (!group) throw Error("问题已回答或已失效，请刷新对话");
        const response = questionAnswer(group, p.answers);
        if (Object.keys(this.ledger).length >= 10000) throw Error("操作记录已满");
        await this.ipc.owner(p.threadId);
        const fresh = this.states.get(p.threadId)?.state;
        if (!fresh || !questionGroups(fresh, desktopTurns(fresh)).some(g => g.id === p.groupId)) throw Error("问题已变化，请刷新对话");
        const record = { digest, threadId: p.threadId, groupId: p.groupId, owner: peer.publicKey, state: "unknown", at: Date.now() };
        this.ledger[p.messageId] = record; await this.saveLedger();
        try {
          await this.ipc.answer(p.threadId, group, response, p.messageId, state.threadRuntimeStatus?.type === "active");
          record.state = "accepted"; await this.saveLedger();
        } catch { /* Never auto-repeat an answer after an ambiguous timeout. */ }
        return record;
      }
      case "send": {
        const thread = await this.authorizeThread(p.threadId);
        if (
          typeof p.text !== "string" ||
          (!p.text.trim() && !p.attachments?.length) ||
          p.text.length > 32000
        )
          throw new Error("消息需为 1–32000 个字符");
        if (!/^[a-zA-Z0-9-]{16,80}$/.test(p.messageId || ""))
          throw new Error("消息 ID 无效");
        const digest = createHash("sha256")
          .update(p.threadId + "\n" + p.text + (p.attachments?.length ? "\n" + JSON.stringify(p.attachments) : ""))
          .digest("hex");
        const old = this.ledger[p.messageId];
        if (old) {
          if (old.digest !== digest || old.owner !== peer.publicKey) throw new Error("消息 ID 已用于其他内容");
          return old;
        }
        const attachments = await this.uploads.resolve(p.attachments || [], p.threadId, peer);
        if (Object.keys(this.ledger).length >= 10000)
          throw new Error("操作记录已满，请在电脑维护连接程序");
        // Resolve the Desktop owner before recording a potentially delivered action.
        await this.ipc.owner(p.threadId);
        const record = {
          digest,
          threadId: p.threadId,
          owner: peer.publicKey,
          state: "unknown",
          at: Date.now(),
        };
        this.ledger[p.messageId] = record;
        await this.saveLedger();
        try {
          this.ipc.follow(p.threadId);
          if (this.states.get(p.threadId)?.state.threadRuntimeStatus?.type === "active") {
            record.text = p.text; record.attachments = attachments; record.mode = "queued";
            await this.saveLedger();
            if (!this.pendingQueued.has(p.threadId)) this.pendingQueued.set(p.threadId, new Set());
            this.pendingQueued.get(p.threadId).add(p.messageId);
            await this.ipc.queue(p.threadId, p.text, p.messageId, attachments, thread.cwd);
          } else { this.monitors.set(p.threadId, { messageId: p.messageId, active: false }); await this.ipc.send(p.threadId, p.text, p.messageId, attachments); record.mode = "start"; }
          record.state = "accepted";
        } catch (e) {
          record.error = "未确认是否已送达，请查看原对话后再决定是否重发";
        }
        await this.saveLedger();
        return record;
      }
      case "queued":
        await this.authorizeThread(p.threadId);
        return { messages: await this.queueRows(p.threadId, peer) };
      case "steerQueued":
      case "removeQueued": {
        await this.authorizeThread(p.threadId);
        const record = this.ledger[p.messageId];
        if (!record || record.owner !== peer.publicKey || record.threadId !== p.threadId || record.mode !== "queued") throw Error("这条等待消息请在电脑操作");
        if (record.queueAction) return record;
        const removed = await this.ipc.removeQueued(p.threadId, p.messageId);
        if (!removed) throw Error("消息已发送或已移除，请刷新对话");
        record.queueAction = method; record.state = "unknown";
        this.pendingQueued.get(p.threadId)?.delete(p.messageId);
        if (!this.pendingQueued.get(p.threadId)?.size) this.pendingQueued.delete(p.threadId);
        await this.saveLedger();
        if (method === "steerQueued") {
          this.monitors.set(p.threadId, { messageId: p.messageId, active: false });
          try {
            if (this.states.get(p.threadId)?.state.threadRuntimeStatus?.type === "active") await this.ipc.steer(p.threadId, record.text, p.messageId, record.attachments);
            else await this.ipc.send(p.threadId, record.text, p.messageId, record.attachments);
            record.state = "accepted";
          } catch { record.error = "引导送达待确认，请查看电脑原对话，不要重复发送"; }
        } else record.state = "accepted";
        await this.saveLedger();
        return record;
      }
      case "stop":
        await this.authorizeThread(p.threadId);
        if (!p.turnId) throw new Error("缺少正在执行的轮次，请刷新");
        await this.ipc.stop(p.threadId, p.turnId);
        return {};
      case "files": {
        const project = await this.fileScope(p.projectId, p.relativePath || "");
        if (project.virtualRoots)
          return {
            files: project.virtualRoots.map((r, i) => ({
              name: path.basename(r),
              relativePath: "@" + i,
              isDirectory: true,
              size: 0,
            })),
            limited: false,
          };
        const dir = await scopedPath(
          [project.path],
          path.resolve(project.path, project.relativePath || "."),
        );
        const entries = await fs.readdir(dir, { withFileTypes: true });
        const rows = [];
        for (const x of entries.slice(0, 200)) {
          try {
            const real = await scopedPath(
              [project.path],
              path.join(dir, x.name),
            );
            const st = await fs.stat(real);
            rows.push({
              name: x.name,
              relativePath:
                project.prefix +
                path.relative(project.path, path.join(dir, x.name)),
              isDirectory: st.isDirectory(),
              size: st.size,
            });
          } catch {}
        }
        return { files: rows, limited: entries.length > 200 };
      }
      case "imageThumbnail": {
        const project = await this.fileScope(p.projectId);
        if (project.virtualRoots) throw Error("请选择图片");
        const real = await this.downloadPath(p, project);
        if (!/\.(png|jpe?g|webp|gif|heic|heif|bmp|tiff?)$/i.test(real)) throw Error("不是图片附件");
        const stat = await fs.stat(real);
        if (!stat.isFile() || stat.size > 25 * 1024 * 1024) throw Error("图片过大，请点按查看原图");
        const key = real + ":" + stat.mtimeMs + ":" + stat.size;
        if (this.thumbnails.has(key)) return this.thumbnails.get(key);
        const { default: sharp } = await import("sharp");
        const data = await sharp(real, { limitInputPixels: 80000000, pages: 1 }).rotate().resize(240, 240, { fit: "cover" }).jpeg({ quality: 75 }).toBuffer();
        if (data.length > 150000) throw Error("缩略图过大");
        const result = { data: data.toString("base64") };
        this.thumbnails.set(key, result);
        while (this.thumbnails.size > 24) this.thumbnails.delete(this.thumbnails.keys().next().value);
        return result;
      }
      case "filePrepare": {
        const project = await this.fileScope(p.projectId, p.relativePath || "");
        if (project.virtualRoots) throw new Error("请选择文件");
        const real = await this.downloadPath(p, project);
        const stat = await fs.stat(real);
        if (!stat.isFile() || stat.size > 200 * 1024 * 1024)
          throw new Error("只能下载不超过 200 MB 的文件");
        await this.cleanLeases();
        if (this.leases.size >= 3)
          throw new Error("同时最多准备 3 个文件，请稍后重试");
        const folder = await fs.mkdtemp(
          path.join(os.tmpdir(), "ifile-transfer-"),
        );
        const file = path.join(folder, "snapshot");
        await fs.copyFile(real, file);
        const after = await fs.stat(real);
        if (after.size !== stat.size || after.mtimeMs !== stat.mtimeMs) {
          await fs.rm(folder, { recursive: true, force: true });
          throw new Error("文件正在变化，请稍后重试");
        }
        const hash = createHash("sha256");
        for await (const b of createReadStream(file)) hash.update(b);
        const id = randomUUID();
        const lease = {
          id,
          file,
          folder,
          peer: peer.publicKey,
          size: stat.size,
          name: path.basename(real),
          sha256: hash.digest("hex"),
          expires: Date.now() + 10 * 60 * 1000,
        };
        this.leases.set(id, lease);
        let direct;
        if (p.direct === true) {
          try { direct = await this.directFiles.link(lease); }
          catch (e) { this.leases.delete(id); await fs.rm(folder, {recursive:true,force:true}); throw e; }
        }
        return {
          id,
          direct,
          size: lease.size,
          name: lease.name,
          sha256: lease.sha256,
          chunkSize: 192 * 1024,
        };
      }
      case "fileChunk": {
        const l = this.leases.get(p.fileId);
        if (!l || l.peer !== peer.publicKey || l.expires < Date.now())
          throw new Error("下载已过期，请重新准备");
        const offset = p.offset;
        if (!Number.isSafeInteger(offset) || offset < 0 || offset > l.size)
          throw new Error("下载位置无效");
        const f = await fs.open(l.file, "r");
        try {
          const buf = Buffer.alloc(Math.min(192 * 1024, l.size - offset));
          const { bytesRead } = await f.read(buf, 0, buf.length, offset);
          return {
            offset,
            data: buf.subarray(0, bytesRead).toString("base64"),
            eof: offset + bytesRead >= l.size,
          };
        } finally {
          await f.close();
        }
      }
      case "fileRelease": {
        const l = this.leases.get(p.fileId);
        if (l?.peer === peer.publicKey) {
          await fs.rm(l.folder, { recursive: true, force: true });
          this.leases.delete(l.id);
        }
        return {};
      }
      default:
        throw new Error("不支持的操作");
    }
  }
  peerNavigation(peer) {
    return this.navigation.peers[peer.publicKey] ||= { pins: {}, read: {} };
  }
  async saveNavigation() {
    // Only compact UI metadata is persisted; no chat bodies are cached here.
    const entries = Object.entries(this.completedThreads).sort((a,b) => b[1]-a[1]).slice(0, 5000);
    this.navigation.completed = this.completedThreads = Object.fromEntries(entries);
    this.navigationQueue = (this.navigationQueue || Promise.resolve()).then(() => saveJSON(path.join(this.stateDir, "navigation.json"), this.navigation));
    return this.navigationQueue;
  }
  badges(peer) {
    const prefs = this.peerNavigation(peer);
    const unread = Object.entries(this.completedThreads).filter(([id, at]) => at > (prefs.read[id] || 0)).map(([id]) => id);
    const runningProjects = this.activity ? [...this.activity.rows.values()].filter(r => this.activity.states.get(r.id)?.status === "active").map(r => r.projectId).filter(Boolean) : [];
    const unreadProjects = unread.map(id => this.completedThreadProjects[id] || this.catalog?.projectFor({id})).filter(Boolean);
    return { unread, runningProjects: [...new Set(runningProjects)], unreadProjects: [...new Set(unreadProjects)] };
  }
  async navigationData(peer) {
    if (!this.catalog) throw Error("请启用电脑目录模式");
    const projects = await this.catalog.refresh();
    const prefs = this.peerNavigation(peer);
    const ids = [...new Set([...(this.catalog.pins || []).filter(id => prefs.pins[id] !== false), ...Object.keys(prefs.pins).filter(id => prefs.pins[id])])].slice(0, 100);
    const pinned = [];
    for (const id of ids) { try { const t = await this.authorizeThread(id); pinned.push({ id, title: (t.name || t.preview || "未命名对话").slice(0,120), projectId: this.catalog.projectFor(t) }); } catch {} }
    return { projects, pinned, ...this.badges(peer) };
  }
  async forkThread(p, peer) {
    const source = await this.authorizeThread(p.threadId);
    if (!/^[a-zA-Z0-9-]{16,80}$/.test(p.requestId || "") || typeof p.turnId !== "string") throw Error("分支请求无效");
    const key = "fork:" + p.requestId, digest = createHash("sha256").update(JSON.stringify([p.threadId,p.turnId])).digest("hex");
    let record = this.ledger[key];
    if (record) {
      if (record.owner !== peer.publicKey || record.digest !== digest) throw Error("分支请求 ID 冲突");
      if (record.result) return record.result;
      throw Error("分支创建结果待核实，请刷新电脑列表，避免重复创建");
    }
    let turn, cursor;
    for (let page=0;page<30;page++) {
      const result = await this.rpc.call("thread/turns/list", { threadId:p.threadId, limit:100, sortDirection:"desc", ...(cursor ? {cursor} : {}) });
      turn = result.data.find(t => t.id === p.turnId); if (turn) break;
      cursor=result.nextCursor; if(!cursor)break;
    }
    if (!turn || turn.status === "inProgress") throw Error("这一轮尚未结束或记录已变化，请选择已完成的回复创建分支");
    if (Object.keys(this.ledger).length >= 10000) throw Error("操作记录已满");
    record = { owner:peer.publicKey, digest, state:"unknown", at:Date.now() }; this.ledger[key]=record; await this.saveLedger();
    const creator = this.rpc.exe ? new CodexRPC(this.rpc.exe,this.rpc.home) : this.rpc;
    try {
      if(creator!==this.rpc) await creator.start();
      const r=await creator.call("thread/fork", {threadId:p.threadId,lastTurnId:p.turnId,excludeTurns:true,deferGoalContinuation:true},35000);
      record.threadId=r.thread.id;await this.saveLedger();
      if (this.catalog) {
        await this.catalog.refresh();
        const localID = this.catalog.projectFor(source);
        const serverID = [...this.catalog.appToLocal].find(([,local]) => local === localID)?.[0] || source.projectId || "";
        await creator.call("thread/metadata/update", { threadId:r.thread.id, projectId:serverID });
      }
      const title=((source.name||source.preview||"对话").slice(0,100))+" · 分支";
      await creator.call("thread/name/set",{threadId:r.thread.id,name:title});
      record.result={thread:{id:r.thread.id,title}};record.state="accepted";await this.saveLedger();
      this.catalog?.pages.clear();return record.result;
    } finally { if(creator!==this.rpc)creator.close(); }
  }
  async saveLedger() {
    this.saveQueue = (this.saveQueue || Promise.resolve()).then(() =>
      saveJSON(path.join(this.stateDir, "operations.json"), this.ledger),
    );
    return this.saveQueue;
  }
  unwatch(peerId) {
    const sub = this.subscribers.get(peerId);
    this.subscribers.delete(peerId);
    if (
      sub && !this.pendingQueued.has(sub.threadId) && !this.monitors.has(sub.threadId) &&
      ![...this.subscribers.values()].some((s) => s.threadId === sub.threadId)
    ) {
      try {
        if (!this.activity?.followed.has(sub.threadId)) this.ipc.follow(sub.threadId, false);
      } catch {}
      this.states.delete(sub.threadId);
      this.historyRefreshNeeded.delete(sub.threadId);
      clearTimeout(this.timers.get(sub.threadId));
      this.timers.delete(sub.threadId);
    }
  }
  async completeQueuedTurns(threadId, turns) {
    const pending = this.pendingQueued.get(threadId);
    if (!pending) return;
    let changed = false;
    for (const id of pending) {
      const record = this.ledger[id];
      if (!record || Date.now() - record.at >= 86400000) { pending.delete(id); continue; }
      const turn = turns.find(t => t.params?.clientUserMessageId === id ||
        (record.startedTurnId && (t.id || t.turnId) === record.startedTurnId) ||
        t.items?.some(i => i.type === "userMessage" && [i.id, i.clientId, i.clientMessageId].includes(id)));
      if (!turn) continue;
      if (!record.startedTurnId) { record.startedTurnId = turn.id || turn.turnId; changed = true; }
      if (["completed", "interrupted", "failed"].includes(turn.status)) {
        record.completedAt = Date.now(); record.outcome = turnOutcome(turn); pending.delete(id); changed = true;
        for (const sub of this.subscribers.values()) if (sub.peer.publicKey === record.owner) sub.peer.emit({ event: "completed", id, threadId, outcome: record.outcome });
      }
    }
    if (!pending.size) this.pendingQueued.delete(threadId);
    if (changed) await this.saveLedger();
  }
  async queueRows(threadId, peer) {
    let rows = this.queued.get(threadId);
    if (!rows) {
      const state = this.codexHome ? await readJSON(path.join(this.codexHome, ".codex-global-state.json"), {}) : {};
      rows = state["queued-follow-ups"]?.[threadId] || [];
    }
    return rows.filter(m => !this.ledger[m.id]?.queueAction).slice(0, 50).map(m => {
      const record = this.ledger[m.id];
      const text = String(m.text || m.context?.prompt || "附件消息").slice(0, 32000);
      const own = record?.owner === peer.publicKey;
      const links = own ? (record.attachments || []).slice(0, 6).map(a => `📎 [${String(a.name || path.basename(a.path)).replace(/[\[\]\n]/g, "")}](<${a.path}>)`) : [];
      return { id: m.id, text, displayText: [text, ...links].join("\n"), editable: own,
        preparing: !!m.preparation, error: m.pausedReason || null };
    });
  }
  onBroadcast(m) {
    if (m.method === "thread-queued-followups-changed" && m.version === 3) {
      const id = m.params?.conversationId;
      if (m.params?.hostId !== "local" || !Array.isArray(m.params.messages)) return;
      this.queued.set(id, m.params.messages);
      while (this.queued.size > 100) this.queued.delete(this.queued.keys().next().value);
      for (const sub of this.subscribers.values()) if (sub.threadId === id) this.queueRows(id, sub.peer).then(messages => sub.peer.emit({ event: "queued", threadId: id, messages })).catch(() => {});
      return;
    }
    if (m.method !== "thread-stream-state-changed") return;
    const id = m.params?.conversationId;
    if (!this.pendingQueued.has(id) && !this.monitors.has(id) && ![...this.subscribers.values()].some((s) => s.threadId === id)) return;
    if (m.version !== 13) {
      for (const s of this.subscribers.values())
        if (s.threadId === id)
          s.peer.emit({
            event: "notice",
            message: "桌面协议版本未适配，实时显示已停止",
          });
      return;
    }
    const previous = this.states.get(id);
    const state = applyChange(previous, m.params.change);
    if (!state) {
      this.states.delete(id);
      this.ipc.follow(id);
      return;
    }
    this.states.set(id, state);
    if (previous?.state.threadRuntimeStatus?.type === "active" && state.state.threadRuntimeStatus?.type === "idle") this.historyRefreshNeeded.add(id);
    this.historyCache.delete(JSON.stringify([id, null]));
    if (this.timers.has(id)) return;
    this.timers.set(
      id,
      setTimeout(async () => {
        this.timers.delete(id);
        const s = this.states.get(id)?.state;
        if (!s) return;
        const turns = desktopTurns(s);
        await this.completeQueuedTurns(id, turns);
        const subscribers = [...this.subscribers.values()].filter(x => x.threadId === id);
        const groups = subscribers.length ? questionGroups(s, turns) : [];
        const active = turns.find((t) =>
          ["inProgress", "running", "active"].includes(t.status),
        );
        const event = {
          event: "timeline",
          threadId: id,
          messages: subscribers.length ? messages(turns, 80000, true, 24, 32) : [],
          questions: groups.map(({ requestId, ...g }) => g),
          progress: progress(s),
          model: s.latestCollaborationMode?.settings?.model || s.latestModel || null,
          reasoningEffort: s.latestReasoningEffort || null,
          status: s.threadRuntimeStatus?.type || "unknown",
          outcome: active || s.threadRuntimeStatus?.type === "active" ? null : turnOutcome(turns.at(-1)),
          turnId: active?.id || active?.turnId || null,
          awaitingApproval: (s.requests || []).some((r) => !r.completed && r.method !== "item/tool/requestUserInput"),
        };
        for (const x of this.subscribers.values())
          if (x.threadId === id) x.peer.emit(event);
        const monitor = this.monitors.get(id);
        if (monitor && (active || event.status === "active")) monitor.active = true;
        const lastTurn = turns.at(-1);
        const fastFailure = monitor && event.outcome?.status === "failed" && lastTurn?.params?.clientUserMessageId === monitor.messageId;
        if (monitor && (monitor.active || fastFailure) && event.status === "idle") {
          const record = this.ledger[monitor.messageId];
          if (record) { record.completedAt = Date.now(); record.outcome = event.outcome; await this.saveLedger(); }
          this.monitors.delete(id);
          for (const x of this.subscribers.values()) if (x.peer.publicKey === record?.owner) x.peer.emit({ event: "completed", id: monitor.messageId, threadId: id, outcome: record.outcome });
          if (!this.pendingQueued.has(id) && !this.activity?.followed.has(id) && ![...this.subscribers.values()].some(x => x.threadId === id)) { this.ipc.follow(id, false); this.states.delete(id); }
        }
        // Live patches already carry the current messages. Read persistence only
        // once when a running turn ends, and only for a phone viewing this chat.
        if (event.status === "idle" && this.historyRefreshNeeded.delete(id) && subscribers.length) {
          try {
            const page = await this.history(id);
            for (const x of this.subscribers.values())
              if (x.threadId === id)
                x.peer.emit({ event: "history", threadId: id, ...page });
          } catch {}
        }
      }, 250),
    );
  }
  async cleanLeases() {
    await this.uploads.clean();
    for (const [id, l] of this.leases)
      if (l.expires < Date.now()) {
        await fs.rm(l.folder, { recursive: true, force: true });
        this.leases.delete(id);
      }
  }
  async close() {
    this.networkTunnels.close();
    await this.directFiles.close();
    this.activity?.close();
    clearInterval(this.leaseTimer);
    await this.uploads.close();
    for (const id of this.pendingQueued.keys()) { try { this.ipc.follow(id, false); } catch {} }
    this.pendingQueued.clear();
    this.historyRefreshNeeded.clear();
    for (const id of this.monitors.keys()) { try { this.ipc.follow(id, false); } catch {} }
    this.monitors.clear();
    for (const id of [...this.subscribers.keys()]) this.unwatch(id);
    for (const l of this.leases.values())
      await fs.rm(l.folder, { recursive: true, force: true });
    this.leases.clear();
  }
}

import fs from "node:fs/promises";
import path from "node:path";
import { randomUUID } from "node:crypto";

// Read only: Desktop's project membership is not the same thing as session cwd.
export class DesktopCatalog {
  constructor({ rpc, codexHome }) {
    this.rpc = rpc;
    this.home = codexHome;
    this.projects = [];
    this.pages = new Map();
  }
  async refresh() {
    const state = JSON.parse(
      await fs.readFile(
        path.join(this.home, ".codex-global-state.json"),
        "utf8",
      ),
    );
    const local = state["local-projects"];
    if (!local || typeof local !== "object")
      throw new Error("无法读取本机 Codex 项目目录，请更新电脑连接程序");
    const mappings =
      state["app-server-project-id-by-legacy-project-id-by-host"] || {};
    this.appToLocal = new Map();
    for (const [host, map] of Object.entries(mappings))
      if (host.startsWith("local:"))
        for (const [legacy, id] of Object.entries(map))
          this.appToLocal.set(id, legacy);
    this.assignments = state["thread-project-assignments"] || {};
    this.membershipHosts = state["thread-project-membership-host-ids"] || {};
    this.projectless = new Set(state["projectless-thread-ids"] || []);
    this.pins = state["pinned-thread-ids"] || [];
    const order = state["project-order"] || [];
    this.projects = Object.values(local)
      .filter((p) => p.id && p.name)
      .map((p) => ({
        id: p.id,
        name: p.name,
        roots: p.rootPaths || [],
        updatedAt: p.updatedAt || 0,
      }));
    this.projects.sort((a, b) => {
      const ai = order.indexOf(a.id),
        bi = order.indexOf(b.id);
      return ai >= 0 && bi >= 0 ? ai - bi : b.updatedAt - a.updatedAt;
    });
    return this.projects;
  }
  projectFor(t) {
    if (this.projectless.has(t.id)) return null;
    const assigned = this.assignments[t.id];
    if (
      assigned?.projectKind === "local" &&
      (!this.membershipHosts[t.id] || this.membershipHosts[t.id] === "local")
    )
      return assigned.projectId;
    return this.appToLocal.get(t.projectId) || t.projectId || null;
  }
  async threads({ projectId, cursor, limit = 10 }) {
    limit = limit === 20 ? 20 : 10;
    await this.refresh();
    if (projectId && !this.projects.some((p) => p.id === projectId))
      throw new Error("本机项目已移除，请刷新");
    for (const [key, page] of this.pages)
      if (Date.now() - page.at > 10 * 60 * 1000) this.pages.delete(key);
    const saved = cursor ? this.pages.get(cursor) : null;
    if (cursor && (!saved || saved.projectId !== (projectId || null)))
      throw new Error("列表已更新，请下拉刷新后重试");
    const rows = saved ? [...saved.remaining] : [];
    let next = saved?.next || null;
    let fetch = !saved || Boolean(next);
    // Keep only summaries on the PC. The phone receives exactly one page (up to 10).
    for (let page = 0; page < 40 && rows.length < limit && fetch; page++) {
      const r = await this.rpc.call("thread/list", {
        limit: projectId ? 100 : limit - rows.length,
        sortKey: "updated_at",
        sortDirection: "desc",
        currentAccountOnly: true,
        archived: false,
        useStateDbOnly: true,
        ...(next ? { cursor: next } : {}),
      });
      for (const t of r.data) {
        if (t.parentThreadId || t.ephemeral) continue;
        const pid = this.projectFor(t);
        if (projectId && pid !== projectId) continue;
        rows.push({
          id: t.id,
          title: (t.name || t.preview || "未命名对话").slice(0, 120),
          updatedAt: t.updatedAt,
          cwd: t.cwd,
          projectId: pid,
          projectName:
            this.projects.find((p) => p.id === pid)?.name || "未分组",
        });
      }
      next = r.nextCursor || null;
      fetch = Boolean(next);
      if (rows.length >= limit || !next) break;
    }
    let nextCursor = null;
    if (rows.length > limit || next) {
      nextCursor = randomUUID();
      this.pages.set(nextCursor, {
        projectId: projectId || null,
        remaining: rows.slice(limit),
        next,
        at: Date.now(),
      });
      while (this.pages.size > 100)
        this.pages.delete(this.pages.keys().next().value);
    }
    return { threads: rows.slice(0, limit), nextCursor };
  }
}

import { parseQuestionReply } from "./questions.mjs";
import { renderFileCitations } from "./file-citations.mjs";
export function applyChange(previous, change) {
  if (change?.type === "snapshot")
    return { revision: change.revision, state: change.conversationState };
  if (
    change?.type !== "patches" ||
    !previous ||
    change.baseRevision !== previous.revision
  )
    return null;
  // Desktop patches are Immer paths. Reject prototype keys before accessing any property.
  let state = structuredClone(previous.state);
  for (const patch of change.patches || []) {
    const p = patch.path;
    if (
      !Array.isArray(p) ||
      p.some((k) =>
        ["__proto__", "prototype", "constructor"].includes(String(k)),
      )
    )
      return null;
    if (!["add", "replace", "remove"].includes(patch.op)) return null;
    if (!p.length) {
      if (patch.op === "remove") return null;
      state = patch.value;
      continue;
    }
    let node = state;
    for (const k of p.slice(0, -1)) {
      if (node == null || !Object.hasOwn(node, k)) return null;
      node = node[k];
    }
    const k = p.at(-1);
    if (Array.isArray(node)) {
      const i = Number(k);
      if (k === "length" && patch.op === "replace") {
        node.length = patch.value;
        continue;
      }
      if (!Number.isInteger(i) || i < 0 || i > node.length) return null;
      if (patch.op === "remove") node.splice(i, 1);
      else if (patch.op === "add") node.splice(i, 0, patch.value);
      else node[i] = patch.value;
    } else if (node && typeof node === "object") {
      if (patch.op === "remove") delete node[k];
      else node[k] = patch.value;
    } else return null;
  }
  return { revision: change.revision, state };
}
function contentText(content) {
  return Array.isArray(content)
    ? content
        .map((x) => {
          if (x.type === "text") return x.text || "";
          if (["localImage", "mention", "localAudio"].includes(x.type) && x.path) {
            const name = (x.name || x.path.split(/[\\/]/).at(-1) || "附件").replace(/[\[\]]/g, "");
            return `📎 [${name}](<${x.path}>)`;
          }
          if (x.type === "image") return "📷 图片附件（在电脑查看原图）";
          return "";
        })
        .join("\n")
    : "";
}
export function taskError(error) {
  if (!error) return null;
  const raw = String(typeof error === "string" ? error : error.message || "").slice(0, 3000);
  const info = error.codexErrorInfo || error.errorInfo;
  const code = typeof info === "string" ? info : Object.keys(info || {})[0];
  const quota = code === "usageLimitExceeded" || /usage limit|insufficient.quota|额度不足|使用上限/i.test(raw);
  return { kind: quota ? "quota" : "error", message: (quota
    ? "Codex 使用额度已达上限，本轮未完成。请等待额度重置，或在电脑端查看套餐与额度。"
    : "本轮未完成：") + (raw ? "\n" + raw : "请在电脑查看详情后重试。") };
}
export function turnOutcome(turn) {
  if (!turn) return null;
  if (turn.status === "failed") return { status: "failed", ...taskError(turn.error || [...(turn.items || [])].reverse().find(i => i.type === "error" && !i.willRetry) || "任务执行失败") };
  if (turn.status === "interrupted") return { status: "interrupted", message: "本轮已停止" };
  if (turn.status === "completed") return { status: "completed" };
  return null;
}
export function messages(turns, budget = 230000, includeCommands = false, maxChats = 50, maxTools = 100) {
  const out = [];
  let bytes = 0;
  for (const turn of turns || []) {
    let hasUser = (turn.items || []).some(
      (i) => (i.type || "").toLowerCase() === "usermessage",
    );
    if (!hasUser && turn.params?.input) {
      const text = contentText(turn.params.input).slice(0, 16000);
      if (text)
        out.push({
          id: (turn.id || turn.turnId) + ":input",
          role: "user",
          text,
          turnId: turn.id || turn.turnId,
          clientMessageId: turn.params.clientUserMessageId || null,
          provisional: true,
          startedAtMs: turn.turnStartedAtMs || null,
        });
    }
    for (const i of turn.items || []) {
      const type = (i.type || "").toLowerCase();
      if (includeCommands && type === "commandexecution") {
        out.push({ id: String(i.id), role: "tool", text: commandSummary(i.command), turnId: turn.id || turn.turnId,
          startedAtMs: i.startedAtMs || turn.turnStartedAtMs || null, toolStatus: i.status || "unknown" });
      }
      if (type !== "usermessage" && type !== "agentmessage") continue;
      let text = i.text || i.message || contentText(i.content);
      if (type === "agentmessage") text = renderFileCitations(text);
      const reply = parseQuestionReply(text);
      if (reply) text = reply.map(r => r.question + "\n" + r.answer).join("\n\n");
      if (!text) continue;
      hasUser ||= type === "usermessage";
      const truncated = text.length > 16000;
      text = text.slice(0, 16000);
      bytes += Buffer.byteLength(text);
      out.push({
        id: String(i.id || `${turn.id}:${out.length}`),
        role: type === "usermessage" ? "user" : "assistant",
        text,
        truncated,
        turnId: turn.id || turn.turnId,
        clientMessageId: i.clientId || i.clientMessageId || null,
        startedAtMs: i.startedAtMs || turn.turnStartedAtMs || null,
        phase: i.phase || null,
        // Only a final answer has an output completion time; progress paragraphs do not.
        completedAtMs: type === "agentmessage" && i.phase === "final_answer" ? i.completedAtMs || null : null,
      });
    }
    const failure = [...(turn.items || [])].reverse().find(i => i.type === "error" && !i.willRetry);
    const error = taskError(turn.error || failure);
    if (error) out.push({ id: (turn.id || turn.turnId) + ":error", role: "error", text: error.message,
      turnId: turn.id || turn.turnId, startedAtMs: failure?.startedAtMs || null });
  }
  // Budget the actual response, not just the number of bubbles.
  let total = 0, chats = 0, tools = 0;
  return out
    .reverse()
    .filter((m) => {
      if (m.role === "tool" ? ++tools > maxTools : ++chats > maxChats) return false;
      total += Buffer.byteLength(JSON.stringify(m));
      return total < budget;
    })
    .reverse();
}

// Desktop v13 can move turns into canonical history islands while turns stays empty.
export function desktopTurns(state) {
  const h = state?.turnHistory?.kind === "canonical" ? state.turnHistory.history : null;
  if (!h) return state?.turns || [];
  const seen = new Set();
  return (h.islands || []).flatMap(island => (island.entries || []).flatMap(e => {
    const key = typeof e.value === "string" ? e.value : e.key;
    const turn = h.entitiesByKey?.[key];
    if (!turn || seen.has(key)) return [];
    seen.add(key); return [turn];
  }));
}
export function progress(state) {
  if (state?.threadRuntimeStatus?.type !== "active") return { label: "", steps: [] };
  const turn = desktopTurns(state).findLast(t => ["inProgress", "running", "active"].includes(t.status));
  const items = turn?.items || [];
  const labels = { commandExecution: "执行命令", mcpToolCall: "调用工具", dynamicToolCall: "调用工具", fileChange: "修改文件", webSearch: "搜索资料" };
  const steps = items.filter(i => labels[i.type]).slice(-6).map(i => ({ id: String(i.id), title: labels[i.type] + (i.tool ? " · " + String(i.tool).slice(0, 80) : ""), active: i.status === "inProgress" || (!i.completedAtMs && i.status !== "completed" && i.status !== "failed"), failed: i.status === "failed" }));
  const last = items.at(-1);
  // Show a generic thinking state, never forward private reasoning content.
  const label = last?.type === "agentMessage" && !last.completedAtMs ? "正在输出…" : last?.type === "reasoning" ? "正在思考…" : steps.some(s => s.active) ? "正在执行操作…" : "正在处理…";
  return { label, steps };
}

export function commandSummary(command) {
  const text = (Array.isArray(command) ? command.join(" ") : String(command || "执行命令")).replace(/\s+/g, " ").trim();
  return text.slice(0, 600);
}

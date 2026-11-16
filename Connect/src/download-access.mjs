import fs from "node:fs/promises";
import path from "node:path";
import { fileCitations } from "./file-citations.mjs";

// A chat grants access to individual assistant-provided links, never to their parent directory.
export function localLinkPath(value) {
  if (typeof value !== "string" || value.length > 4096 || value.includes("\0")) return null;
  let s = value.trim();
  if (s.startsWith("<") && s.endsWith(">")) s = s.slice(1, -1);
  if (/^file:\/\//i.test(s)) return null;
  s = s.replace(/:\d+(?::\d+)?$/, "");
  return path.isAbsolute(s) ? path.normalize(s) : null;
}
export function assistantLinks(items) {
  const paths = [];
  for (const item of items) {
    if ((item.type || "").toLowerCase() !== "agentmessage") continue;
    const text = item.text || item.message || "";
    for (const citation of fileCitations(text)) {
      const p = localLinkPath(citation.path);
      if (p) paths.push(p);
    }
    for (const m of text.matchAll(/\[[^\]\n]*\]\(\s*(?:<([^>\n]+)>|([^\s]+))\s*\)/g)) {
      const p = localLinkPath(m[1] || m[2]);
      if (p) paths.push(p);
    }
  }
  return paths;
}
export async function matchesLinkedFile(target, items) {
  const equal = (a, b) => process.platform === "win32" ? a.toLowerCase() === b.toLowerCase() : a === b;
  const attachments = items.filter(i => (i.type || "").toLowerCase() === "usermessage")
    .flatMap(i => Array.isArray(i.content) ? i.content : [])
    .filter(c => ["localImage", "mention", "localAudio"].includes(c.type))
    .map(c => localLinkPath(c.path)).filter(Boolean);
  for (const link of [...assistantLinks(items), ...attachments]) {
    // Require both the spelled path and canonical target. This does not authorize aliases or siblings.
    if (!equal(path.resolve(link), path.resolve(target))) continue;
    try { return await fs.realpath(link); } catch { throw Error("对话中的文件已移动或删除，请让电脑重新提供文件"); }
  }
  return null;
}

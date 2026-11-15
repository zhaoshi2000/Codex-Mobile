import fs from "node:fs/promises";
import path from "node:path";
export async function saveJSON(file, value) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  const tmp = file + ".tmp";
  await fs.writeFile(tmp, JSON.stringify(value, null, 2), { mode: 0o600 });
  await fs.rename(tmp, file);
}
export async function readJSON(file, fallback) {
  try {
    return JSON.parse(await fs.readFile(file, "utf8"));
  } catch (e) {
    if (e.code === "ENOENT") return fallback;
    throw e;
  }
}
export function inside(root, target) {
  const r = path.relative(root, target);
  return (
    r === "" ||
    (!r.startsWith(".." + path.sep) && r !== ".." && !path.isAbsolute(r))
  );
}
export async function scopedPath(roots, target) {
  const real = await fs.realpath(target);
  if (!roots.some((root) => inside(root, real)))
    throw new Error("此路径未授权给手机");
  return real;
}

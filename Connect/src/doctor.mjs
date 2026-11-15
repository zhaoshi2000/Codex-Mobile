import fs from "node:fs/promises";
import { CodexRPC } from "./rpc.mjs";
import { DesktopIPC } from "./desktop.mjs";
const config = JSON.parse(
  await fs.readFile(process.argv[2] || "bridge.config.json", "utf8"),
);
const rpc = new CodexRPC(config.codexExecutable || "codex", config.codexHome),
  ipc = new DesktopIPC(config.ipcSocket);
try {
  await rpc.start();
  console.log("PASS: Codex read API");
  await ipc.connect();
  console.log("PASS: Desktop IPC");
  for (const root of config.projects) {
    await fs.access(root);
    const result = await rpc.call("thread/list", {
      cwd: root,
      limit: 1,
      useStateDbOnly: true,
      sourceKinds: ["cli", "vscode", "appServer", "unknown"],
    });
    console.log(
      `PASS: configured project (${result.data.length ? "history available" : "no conversations yet"})`,
    );
  }
  console.log("检查完成。此检查不会发送消息或修改项目。");
} catch (e) {
  console.error("FAIL: " + e.message);
  process.exitCode = 1;
} finally {
  ipc.close();
  rpc.close();
}

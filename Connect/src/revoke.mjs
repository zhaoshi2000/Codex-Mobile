import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { saveJSON } from "./storage.mjs";
const config = JSON.parse(
  await fs.readFile(process.argv[2] || "bridge.config.json", "utf8"),
);
const file = path.join(
  config.stateDir || path.join(os.homedir(), ".ifileplus-connect"),
  "device.json",
);
const device = JSON.parse(await fs.readFile(file, "utf8"));
device.trusted = [];
await saveJSON(file, device);
console.log("已撤销所有手机。请重启连接程序以断开现有连接，并生成新配对码。");

import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const adminDir = path.dirname(fileURLToPath(import.meta.url));
const dist = path.join(adminDir, 'dist');
const assets = await fs.readdir(path.join(dist, 'assets'));
const scripts = assets.filter((name) => name.endsWith('.js'));
const styles = assets.filter((name) => name.endsWith('.css'));
if (scripts.length !== 1 || styles.length !== 1)
  throw new Error('后台构建须生成一份 JavaScript 和一份 CSS');

const css = await fs.readFile(path.join(dist, 'assets', styles[0]), 'utf8');
const js = await fs.readFile(path.join(dist, 'assets', scripts[0]), 'utf8');
const html = `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="theme-color" content="#0c1220"><title>AstroGate · 中转管理控制台</title><style>${css.replaceAll('</style', '<\\/style')}</style></head><body><div id="app"></div><script type="module">${js.replaceAll('</script', '<\\/script')}</script></body></html>`;
const output = path.join(adminDir, '..', 'src', 'relay-admin-page.mjs');
await fs.writeFile(output, `// Generated from Connect/admin. Run npm run build:admin after editing the Vue source.\nexport const adminPage = ${JSON.stringify(html)};\n`);
console.log(`Embedded Vue admin: ${Buffer.byteLength(html)} bytes`);

import http from 'node:http';
import { createHash, timingSafeEqual } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { MAX_SPEECH_BODY, validateSpeech } from './speech.mjs';

export function createSpeechRelay({ token, configPath, worker = 'http://127.0.0.1:18891/stream', fetchImpl = fetch }) {
  if (!token || token.length < 32) throw Error('Speech relay requires a host credential');
  let active = 0;
  const authorized = async (header) => {
    if (typeof header !== 'string' || !header.startsWith('Bearer ')) return false;
    const credential = header.slice(7);
    if (credential.length < 32 || credential.length > 256) return false;
    const supplied = createHash('sha256').update(credential).digest();
    const legacy = createHash('sha256').update(token).digest();
    if (timingSafeEqual(supplied, legacy)) return true;
    if (!configPath) return false;
    try {
      const state = JSON.parse(await readFile(configPath, 'utf8'));
      for (const key of Array.isArray(state.keys) ? state.keys : []) {
        if (typeof key.hash !== 'string' || !/^[a-f0-9]{64}$/.test(key.hash)) continue;
        if (timingSafeEqual(supplied, Buffer.from(key.hash, 'hex'))) return true;
      }
    } catch { /* Fail closed for generated keys if the store cannot be read. */ }
    return false;
  };
  const reply = (res, status, data) => {
    res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    res.end(JSON.stringify(data));
  };
  const server = http.createServer(async (req, res) => {
    if (req.url === '/health' && req.method === 'GET') return reply(res, 200, { service: 'astrogate-speech-relay' });
    if (req.url !== '/speech' || req.method !== 'POST') return reply(res, 404, { error: 'not_found' });
    if (!(await authorized(req.headers.authorization))) return reply(res, 401, { error: 'unauthorized' });
    if (active >= 4) return reply(res, 429, { error: 'busy' });
    const length = Number(req.headers['content-length']);
    if (!Number.isInteger(length) || length < 32 || length > MAX_SPEECH_BODY) return reply(res, 413, { error: 'audio_size' });
    if (req.headers['content-type'] !== 'application/json') return reply(res, 415, { error: 'audio_type' });
    active++;
    try {
      let size = 0; const chunks = [];
      for await (const chunk of req) {
        size += chunk.length;
        if (size > MAX_SPEECH_BODY) { reply(res, 413, { error: 'audio_size' }); return; }
        chunks.push(chunk);
      }
      if (size !== length) return reply(res, 400, { error: 'incomplete_audio' });
      let chunk;
      try { chunk = validateSpeech(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
      catch { return reply(res, 422, { error: 'invalid_chunk' }); }
      const result = await fetchImpl(worker, { method: 'POST', body: JSON.stringify(chunk),
        headers: { 'Content-Type': 'application/json' }, signal: AbortSignal.timeout(12000), redirect: 'error' });
      if (!result.ok) return reply(res, [409, 413, 422, 503].includes(result.status) ? result.status : 502, { error: 'recognition_failed' });
      const data = await result.json();
      if (typeof data.text !== 'string' || data.text.length > 12000) return reply(res, 502, { error: 'invalid_result' });
      reply(res, 200, { text: data.text, sequence: data.sequence, final: data.final === true });
    } catch (error) {
      if (!res.headersSent) reply(res, error.name === 'TimeoutError' ? 504 : 503, { error: 'worker_unavailable' });
    } finally { active--; }
  });
  server.requestTimeout = 15000;
  server.headersTimeout = 10000;
  return server;
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  createSpeechRelay({ token: process.env.IFILE_RELAY_TOKEN, configPath: process.env.IFILE_RELAY_CONFIG_PATH,
    worker: process.env.SPEECH_WORKER_URL })
    .listen(Number(process.env.PORT || 18892), process.env.BIND_HOST || '127.0.0.1');
}

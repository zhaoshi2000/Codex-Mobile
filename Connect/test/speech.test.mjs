import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createHash, randomUUID } from 'node:crypto';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { speechClient, validateSpeech, MAX_SPEECH_BYTES } from '../src/speech.mjs';
import { createSpeechRelay } from '../src/speech-relay.mjs';

const chunk = () => ({ requestId: randomUUID(), sequence: 0, audio: Buffer.alloc(16000).toString('base64'), final: false });
const token = 'speech-test-credential-'.repeat(3);

test('speech chunks enforce format, size, sequence and explicit final marker', () => {
  assert.equal(validateSpeech(chunk()).sequence, 0);
  assert.doesNotThrow(() => validateSpeech({ ...chunk(), audio: '', final: true }));
  for (const change of [{ sequence: -1 }, { sequence: 241 }, { final: 'yes' }, { audio: '' },
    { audio: 'bad*' }, { audio: Buffer.alloc(3).toString('base64') },
    { audio: Buffer.alloc(MAX_SPEECH_BYTES + 2).toString('base64') }, { requestId: '../invalid' }]) {
    assert.throws(() => validateSpeech({ ...chunk(), ...change }));
  }
});

test('PC forwards PCM to same TLS relay with host auth and preserves partial results', async () => {
  let request;
  const client = speechClient({ relay: 'wss://relay.example/ifile-connect/', token,
    fetchImpl: async (url, options) => {
      request = { url: String(url), ...options };
      const sent = JSON.parse(options.body);
      return Response.json({ text: '实时文字', sequence: sent.sequence, final: false });
    } });
  const result = await client(chunk());
  assert.equal(result.text, '实时文字'); assert.equal(result.final, false);
  assert.equal(request.url, 'https://relay.example/ifile-connect/speech');
  assert.equal(request.headers.Authorization, 'Bearer ' + token);
  assert.equal(request.redirect, 'error');
  assert.equal(JSON.parse(request.body).audio.length, chunk().audio.length);
  await assert.rejects(speechClient({ relay: 'ws://plain.example', token })(chunk()), /HTTPS/);
});

test('speech errors explain missing deployment, offline worker and expired session', async () => {
  for (const [status, message] of [[404, /尚未启用/], [401, /验证失败/], [503, /离线或繁忙/], [409, /已过期/], [504, /超时/]]) {
    await assert.rejects(speechClient({ relay: 'wss://relay.example', token,
      fetchImpl: async () => new Response('', { status }) })(chunk()), message);
  }
});

test('relay rejects unauthenticated and malformed audio before forwarding', async () => {
  let forwarded = 0;
  const server = createSpeechRelay({ token, fetchImpl: async (_, options) => {
    forwarded++; const sent = JSON.parse(options.body);
    return Response.json({ text: '你好', sequence: sent.sequence, final: sent.final });
  } });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const url = `http://127.0.0.1:${server.address().port}/speech`;
  const post = (data, authorization = 'Bearer ' + token) => fetch(url, { method: 'POST',
    headers: { Authorization: authorization, 'Content-Type': 'application/json' }, body: JSON.stringify(data) });
  try {
    assert.equal((await post(chunk(), 'wrong')).status, 401);
    assert.equal((await post({ ...chunk(), audio: 'invalid' })).status, 422);
    assert.equal(forwarded, 0);
    const result = await post(chunk()); assert.equal(result.status, 200);
    assert.deepEqual(await result.json(), { text: '你好', sequence: 0, final: false });
    assert.equal(forwarded, 1);
  } finally { await new Promise(resolve => server.close(resolve)); }
});

test('speech relay accepts new admin keys and revocation without restart while retaining the legacy key', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'astrogate-speech-keys-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const configPath = join(directory, 'relay-config.json');
  const newKey = 'new-speech-and-host-key-'.repeat(3);
  const hash = createHash('sha256').update(newKey).digest('hex');
  await writeFile(configPath, JSON.stringify({ version: 1, publicWss: 'wss://example.test/ifile-connect',
    keys: [{ id: randomUUID(), name: '新电脑', hash, createdAt: new Date().toISOString() }] }));
  let calls = 0;
  const server = createSpeechRelay({ token, configPath, fetchImpl: async (_, options) => {
    calls++;
    return Response.json({ text: '可以识别', sequence: JSON.parse(options.body).sequence });
  } });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(() => new Promise(resolve => server.close(resolve)));
  const url = `http://127.0.0.1:${server.address().port}/speech`;
  const send = (key) => fetch(url, { method: 'POST', headers: {
    Authorization: 'Bearer ' + key, 'Content-Type': 'application/json',
  }, body: JSON.stringify(chunk()) });
  assert.equal((await send(newKey)).status, 200);
  assert.equal((await send(token)).status, 200);
  assert.equal((await send('not-a-real-key-'.repeat(4))).status, 401);
  await writeFile(configPath, JSON.stringify({ version: 1, keys: [] }));
  assert.equal((await send(newKey)).status, 401);
  assert.equal((await send(token)).status, 200);
  await writeFile(configPath, '{bad json');
  assert.equal((await send(newKey)).status, 401);
  assert.equal(calls, 3);
});

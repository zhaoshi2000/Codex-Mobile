import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { WebSocket } from 'ws';
import { createRelay } from '../src/relay.mjs';

const legacy = 'legacy-relay-token-that-is-long-enough-for-tests';
const password = 'separate-long-admin-password-for-tests';
const auth = { Authorization: 'Basic ' + Buffer.from('admin:' + password).toString('base64') };
const upgrade = (port, token) => new Promise((resolve) => {
  const socket = new WebSocket(`ws://127.0.0.1:${port}/host/${randomUUID()}`, {
    headers: { Authorization: 'Bearer ' + token },
  });
  socket.once('open', () => { socket.close(); resolve(true); });
  socket.once('unexpected-response', (_, response) => { socket.terminate(); resolve(response.statusCode); });
  socket.once('error', () => resolve(false));
});

test('admin requires separate login; new keys persist, can be revoked, and legacy remains valid', async (t) => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'relay-admin-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const configPath = path.join(directory, 'admin.json');
  const options = { token: legacy, adminPassword: password, configPath,
    publicWss: 'wss://relay.example/ifile-connect', port: 0 };
  let relay = createRelay(options);
  let port = await relay.start();
  t.after(async () => { await relay.close(); });
  const url = (suffix) => `http://127.0.0.1:${port}/admin${suffix}`;
  assert.equal((await fetch(url('/'))).status, 401);
  assert.equal((await fetch(url('/'), { headers: { Authorization: 'Bearer ' + legacy } })).status, 401);
  const page = await fetch(url('/'), { headers: auth });
  assert.equal(page.status, 200);
  assert.match(await page.text(), /中转管理/);
  const stateResponse = await fetch(url('/api/state'), { headers: auth });
  const state = await stateResponse.json();
  assert.equal(state.publicWss, options.publicWss);
  assert.deepEqual(state.keys, []);
  assert.ok(!JSON.stringify(state).includes(legacy));
  const keyBody = JSON.stringify({ name: '家里的电脑' });
  assert.equal((await fetch(url('/api/keys'), { method: 'POST', headers: auth, body: keyBody })).status, 404);
  assert.equal((await fetch(url('/api/keys'), { method: 'POST', headers: { ...auth, 'X-AstroGate-Admin': '1', Origin: 'https://evil.example' }, body: keyBody })).status, 403);
  const added = await fetch(url('/api/keys'), { method: 'POST', headers: { ...auth, 'X-AstroGate-Admin': '1' }, body: keyBody });
  assert.equal(added.status, 201);
  const key = await added.json();
  assert.ok(key.token.length >= 32);
  assert.equal(await upgrade(port, key.token), true);
  assert.equal(await upgrade(port, legacy), true);
  const disk = await fs.readFile(configPath, 'utf8');
  assert.ok(!disk.includes(key.token));
  assert.ok(!disk.includes(password));
  assert.ok(!disk.includes(legacy));
  await relay.close();
  relay = createRelay(options);
  port = await relay.start();
  assert.equal(await upgrade(port, key.token), true);
  const removed = await fetch(url('/api/keys/' + key.id), { method: 'DELETE', headers: { ...auth, 'X-AstroGate-Admin': '1' } });
  assert.equal(removed.status, 200);
  assert.equal(await upgrade(port, key.token), 403);
  assert.equal(await upgrade(port, legacy), true);
});

test('admin rejects weak password and invalid public URL', () => {
  assert.throws(() => createRelay({ token: legacy, adminPassword: 'short', configPath: '/tmp/admin.json' }), /8/);
  assert.throws(() => createRelay({ token: legacy, adminUsername: 'bad:name', adminPassword: password, configPath: '/tmp/admin.json' }), /USERNAME/);
  assert.throws(() => createRelay({ token: legacy, adminPassword: password, configPath: '/tmp/admin.json', publicWss: 'ws://plain.example' }), /wss/);
});

test('configured nine-digit admin login replaces the default username', async (t) => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'relay-admin-user-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const username = '876543210';
  const nineDigitPassword = '123456789';
  const relay = createRelay({ token: legacy, adminUsername: username, adminPassword: nineDigitPassword,
    configPath: path.join(directory, 'admin.json'), publicWss: 'wss://relay.example/ifile-connect', port: 0 });
  const port = await relay.start();
  t.after(() => relay.close());
  const url = `http://127.0.0.1:${port}/admin/api/state`;
  const login = (user, pass) => ({ Authorization: 'Basic ' + Buffer.from(`${user}:${pass}`).toString('base64') });
  assert.equal((await fetch(url, { headers: login('admin', nineDigitPassword) })).status, 401);
  assert.equal((await fetch(url, { headers: login(username, password) })).status, 401);
  assert.equal((await fetch(url, { headers: login(username, nineDigitPassword) })).status, 200);
});

test('repeated failed admin logins are throttled without affecting relay health', async (t) => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'relay-admin-rate-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const relay = createRelay({ token: legacy, adminPassword: password,
    configPath: path.join(directory, 'admin.json'), publicWss: 'wss://relay.example/ifile-connect', port: 0 });
  const port = await relay.start();
  t.after(() => relay.close());
  const url = `http://127.0.0.1:${port}`;
  for (let index = 0; index < 30; index++)
    assert.equal((await fetch(url + '/admin/api/state')).status, 401);
  assert.equal((await fetch(url + '/admin/api/state', { headers: auth })).status, 429);
  assert.equal((await fetch(url + '/health')).status, 200);
});

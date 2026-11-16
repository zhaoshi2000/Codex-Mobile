import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Bridge } from '../src/bridge.mjs';
import { createRelay } from '../src/relay.mjs';
import { WireClient } from './wire-client.mjs';

test('two computers share a relay without mixing identities, pairing, or responses', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'astrogate-two-pcs-'));
  const token = 'multiple-computers-test-'.repeat(3);
  const relay = createRelay({ token, port: 0 });
  const bridges = [], phones = [];
  try {
    const port = await relay.start();
    for (const name of ['First PC', 'Second PC']) {
      const bridge = new Bridge({
        name, relay: `ws://127.0.0.1:${port}`, relayToken: token,
        stateDir: path.join(root, name), allowLocal: true,
        gateway: { unwatch() {}, async close() {}, async handle() { return { name }; } },
      });
      bridges.push(bridge);
      await bridge.init();
      await bridge.connect();
      const phone = new WireClient(bridge.qr);
      phones.push(phone);
      await phone.connect();
    }
    assert.notEqual(bridges[0].device.hostId, bridges[1].device.hostId);
    assert.notEqual(bridges[0].device.key.x, bridges[1].device.key.x);
    assert.deepEqual(await Promise.all(phones.map(p => p.request('projects'))), [
      { name: 'First PC' }, { name: 'Second PC' },
    ]);
    assert.equal(bridges[0].device.trusted.length, 1);
    assert.equal(bridges[1].device.trusted.length, 1);
    phones[0].close();
    await bridges[0].close();
    assert.deepEqual(await phones[1].request('projects'), { name: 'Second PC' });
    const saved = JSON.parse(await fs.readFile(path.join(root, 'First PC', 'device.json')));
    assert.equal(saved.hostId, bridges[0].device.hostId);
    assert.equal(saved.trusted.length, 1);
  } finally {
    for (const phone of phones) phone.close();
    for (const bridge of bridges) await bridge.close();
    await relay.close();
    await fs.rm(root, { recursive: true, force: true });
  }
});

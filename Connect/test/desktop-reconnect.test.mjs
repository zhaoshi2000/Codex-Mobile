import test from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { setTimeout as sleep } from 'node:timers/promises';
import { DesktopIPC } from '../src/desktop.mjs';

function frame(value) {
  const b = Buffer.from(JSON.stringify(value)), h = Buffer.alloc(4);
  h.writeUInt32LE(b.length); return Buffer.concat([h, b]);
}

test('large fragmented snapshots and adjacent frames arrive intact and release their buffers', () => {
  const ipc=new DesktopIPC(),seen=[];ipc.on('broadcast',m=>seen.push(m));
  const first={type:'broadcast',method:'snapshot',text:'中'.repeat(1000000)};
  const second={type:'broadcast',method:'next'};const data=Buffer.concat([frame(first),frame(second)]);
  for(let i=0;i<data.length;i+=1031)ipc.read(data.subarray(i,i+1031));
  assert.deepEqual(seen,[first,second]);assert.equal(ipc.bufferLength,0);assert.equal(ipc.buffer.length,0);
});
async function until(check) {
  const end = Date.now() + 3000;
  while (!check()) { assert.ok(Date.now() < end, 'condition timed out'); await sleep(10); }
}
async function fixture(t, handle = () => false) {
  const sockets = [], requests = [];
  const server = net.createServer(socket => {
    sockets.push(socket); socket.on('error', () => {});
    let buffer = Buffer.alloc(0);
    socket.on('data', b => {
      buffer = Buffer.concat([buffer, b]);
      while (buffer.length >= 4 && buffer.length >= buffer.readUInt32LE() + 4) {
        const size = buffer.readUInt32LE(), m = JSON.parse(buffer.subarray(4, size + 4));
        buffer = buffer.subarray(size + 4); requests.push(m);
        if (handle(m, socket, sockets.length)) continue;
        if (m.type === 'request') socket.write(frame({ type: 'response', requestId: m.requestId,
          resultType: 'success', result: { clientId: 'fixture-client' } }));
      }
    });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const ipc = new DesktopIPC({ host: '127.0.0.1', port: server.address().port }, { retryMs: 20, timeoutMs: 80 });
  t.after(async () => { ipc.close(); sockets.forEach(s => s.destroy()); await new Promise(r => server.close(r)); });
  return { ipc, sockets, requests };
}

test('malformed desktop frame reconnects and restores follows instead of permanently stopping', async t => {
  const { ipc, sockets, requests } = await fixture(t);
  await ipc.connect(); ipc.follow('thread-123456');
  await until(() => requests.some(m => m.method === 'thread-stream-following-changed'));
  sockets[0].write(Buffer.from([1, 0, 0, 0, 123])); // truncated JSON, complete frame
  await until(() => sockets.length === 2 && ipc.connected);
  await until(() => requests.filter(m => m.method === 'thread-stream-following-changed').length === 2);
  assert.equal(ipc.stopping, false); assert.equal(ipc.lastError, null);
  const event = { type: 'broadcast', method: 'fresh-snapshot' }, seen = [];
  ipc.on('broadcast', m => seen.push(m));
  const b = frame(event); sockets[1].write(b.subarray(0, 2)); sockets[1].write(b.subarray(2));
  await until(() => seen.length === 1); assert.deepEqual(seen[0], event);
});

test('desktop handshake timeout closes half-open socket and retries automatically', async t => {
  const { ipc, sockets } = await fixture(t, (m, socket, n) => n === 1);
  await assert.rejects(ipc.connect(), /待核实/);
  await until(() => sockets.length === 2 && ipc.connected);
  assert.equal(sockets[0].destroyed, true);
});

test('uncertain mutation is rejected and never replayed when the desktop recovers', async t => {
  const { ipc, sockets, requests } = await fixture(t, m => m.method === 'thread-follower-start-turn');
  await Promise.all([ipc.connect(), ipc.connect()]);
  assert.equal(sockets.length, 1);
  await assert.rejects(ipc.request('thread-follower-start-turn', {}), /待核实/);
  await until(() => sockets.length === 2 && ipc.connected);
  assert.equal(requests.filter(m => m.method === 'thread-follower-start-turn').length, 1);
  ipc.close(); await sleep(70); assert.equal(sockets.length, 2);
});

test('oversized and null frames do not permanently disable desktop recovery', async t => {
  const { ipc, sockets } = await fixture(t); await ipc.connect();
  const header = Buffer.alloc(4); header.writeUInt32LE(32 * 1024 * 1024 + 1);
  sockets[0].write(header);
  await until(() => sockets.length === 2 && ipc.connected);
  sockets[1].write(frame(null));
  await until(() => sockets.length === 3 && ipc.connected);
  assert.equal(ipc.stopping, false);
});

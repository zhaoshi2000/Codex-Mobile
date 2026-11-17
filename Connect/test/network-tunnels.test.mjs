import test from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { once } from 'node:events';
import { NetworkTunnels } from '../src/network-tunnels.mjs';

test('paired service tunnel carries binary data, isolates owners and cleans up', async () => {
  const server = net.createServer(s => s.on('data', b => s.write(b)));
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const tunnels = new NetworkTunnels();
  try {
    const {id} = await tunnels.open('phone-a','127.0.0.1',server.address().port);
    assert.throws(()=>tunnels.read('phone-b', id), /关闭/);
    await assert.rejects(tunnels.write('phone-b', id, 'aA=='), /关闭/);
    const payload = Buffer.from([0,255,13,10,128,1]);
    await tunnels.write('phone-a',id,payload.toString('base64'));
    let result = Buffer.alloc(0);
    for(let i=0;i<100&&!result.length;i++) {
      await new Promise(r=>setTimeout(r,10));
      result = Buffer.from(tunnels.read('phone-a',id).data,'base64');
    }
    assert.deepEqual(result,payload);
    tunnels.closeOwner('phone-b'); assert.equal(tunnels.sessions.size,1);
    tunnels.closeOwner('phone-a'); assert.equal(tunnels.sessions.size,0);
  } finally { tunnels.close(); await new Promise(r=>server.close(r)); }
});
test('tunnels reject other LAN hosts, metadata and oversized writes', async () => {
  const tunnels = new NetworkTunnels();
  await assert.rejects(tunnels.open('a','169.254.169.254',80), /本机/);
  await assert.rejects(tunnels.open('a','192.168.1.1',80), /本机/);
  await assert.rejects(tunnels.open('a','localhost',0), /端口/);
  tunnels.sessions.set('id',{owner:'a'});
  await assert.rejects(tunnels.write('a','id',Buffer.alloc(65537).toString('base64')), /过大/);
});

import test from 'node:test';import assert from 'node:assert/strict';
import fs from 'node:fs/promises';import os from 'node:os';import path from 'node:path';
import {createRelay} from '../src/relay.mjs';import {Bridge} from '../src/bridge.mjs';import {WireClient} from './wire-client.mjs';

for (const blockedMethod of ['history', 'activity', 'imageThumbnail']) test(`encrypted phone actions bypass slow ${blockedMethod}; writes retain order`,async t=>{
  const dir=await fs.mkdtemp(path.join(os.tmpdir(),'astro-history-wire-'));
  const token='history-wire-test-'.repeat(3),relay=createRelay({token,port:0});
  const port=await relay.start();let release,started;
  const historyStarted=new Promise(r=>{started=r;});
  const hold=new Promise(r=>{release=r;});const writes=[];
  const gateway={unwatch(){},async close(){},async handle(method,p){
    if(method===blockedMethod){started();await hold;return {messages:[{id:'answer',role:'assistant',text:'done'}]};}
    if(method==='watch')return {writable:true};
    if(method==='models')return {current:{model:'fixture-model'}};
    if(method==='send'){await new Promise(r=>setTimeout(r,15));writes.push(p.messageId);return {state:'accepted'};}
    return {ok:true};
  }};
  const bridge=new Bridge({relay:`ws://127.0.0.1:${port}`,relayToken:token,stateDir:dir,name:'fixture',gateway,allowLocal:true});
  await bridge.init();await bridge.connect();const phone=new WireClient(bridge.qr);
  t.after(async()=>{release();phone.close();await bridge.close();await relay.close();await fs.rm(dir,{recursive:true,force:true});});
  await phone.connect();const history=phone.request(blockedMethod);await historyStarted;
  const watchdog=setTimeout(release,2000);
  try {
    const before=Date.now();
    const watch=await phone.request('watch');assert.equal(watch.writable,true);
    assert.equal((await phone.request('models')).current.model,'fixture-model');
    await phone.request('ping');
    const [a,b]=await Promise.all([phone.request('send',{messageId:'first'}),phone.request('send',{messageId:'second'})]);
    assert.equal(a.state,'accepted');assert.equal(b.state,'accepted');assert.deepEqual(writes,['first','second']);
    assert.ok(Date.now()-before<1500,'history must not block control requests');
  }finally{clearTimeout(watchdog);release();}
  assert.equal((await history).messages[0].text,'done');
});

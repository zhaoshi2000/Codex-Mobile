import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { DesktopActivity } from '../src/activity.mjs';

test('running task summaries use Desktop runtime snapshots and patches, never DB notLoaded or chat bodies', async () => {
  const ipc = new EventEmitter(); ipc.owner = async id => { if(id === 'closed') throw Error('no owner'); };
  ipc.follow = (id, enabled = true) => { if (enabled) ipc.emit('broadcast', {method:'thread-stream-state-changed',version:13,params:{conversationId:id,change:{type:'snapshot',revision:1,conversationState:{threadRuntimeStatus:{type:id === 'active'?'active':'idle',activeFlags:[]},turns:[{secret:'must not retain transcript'}]}}}}); };
  const rpc = {call:async () => ({data:['active','idle','closed'].map(id=>({id,name:id,status:{type:'notLoaded'}})),nextCursor:null})};
  const catalog = {refresh:async()=>{},projectFor:()=>null,projects:[]};
  const a = new DesktopActivity({rpc,ipc,catalog});
  try {
    assert.deepEqual((await a.list()).tasks.map(x=>x.id),['active']);
    assert.ok(!JSON.stringify([...a.states]).includes('secret'));
    ipc.emit('broadcast',{method:'thread-stream-state-changed',version:13,params:{conversationId:'active',change:{type:'patches',baseRevision:1,revision:2,patches:[{op:'replace',path:['threadRuntimeStatus','type'],value:'idle'}]}}});
    assert.deepEqual((await a.list()).tasks,[]);
    ipc.emit('broadcast',{method:'thread-stream-state-changed',version:13,params:{conversationId:'idle',change:{type:'patches',baseRevision:1,revision:2,patches:[{op:'replace',path:['threadRuntimeStatus'],value:{type:'active',activeFlags:['waitingOnApproval']}}]}}});
    assert.equal((await a.list()).tasks[0].awaitingApproval,true);
    ipc.connected=false;ipc.emit('closed');await assert.rejects(a.list());assert.equal(a.states.size,0);
  } finally { a.close(); }
});

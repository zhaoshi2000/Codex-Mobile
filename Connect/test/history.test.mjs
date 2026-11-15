import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {EventEmitter} from 'node:events';
import {Gateway} from '../src/gateway.mjs';
import {messages} from '../src/timeline.mjs';

async function fixture(t, rows) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'astro-history-'));
  const rpc = {call: async (method,p) => {
    if(method === 'thread/read') return {thread:{cwd:dir}};
    const start=Number(p.cursor||0), end=start+p.limit;
    return {data:rows.slice(start,end),nextCursor:end<rows.length?String(end):null};
  }};
  const ipc=new EventEmitter();ipc.follow=()=>{};ipc.owner=async()=> 'owner';
  const g=new Gateway({rpc,ipc,stateDir:dir,roots:[dir]});await g.init();
  t.after(async()=>{await g.close();await fs.rm(dir,{recursive:true,force:true});});return g;
}
test('reopening during a tool-heavy turn retains its photo input and preceding download reply', async t=>{
  const rows=[...Array.from({length:240},(_,i)=>({turnId:'current',item:{type:'commandExecution',id:'tool'+i,text:'private output'}})),
    {turnId:'current',item:{id:'question',type:'userMessage',content:[{type:'text',text:'Please inspect'},{type:'localImage',path:'D:/project/photo.jpg'}]}},
    {turnId:'previous',item:{id:'download',type:'agentMessage',text:'[Download](<C:/Users/test/Desktop/build.ipa>)'}}];
  const g=await fixture(t,rows);
  for(let reopen=0;reopen<2;reopen++) {
    const page=await g.history('thread-history-123');
    assert.deepEqual(page.messages.filter(m=>m.role!=='tool').map(m=>m.id),['download','question']);
    assert.match(page.messages[1].text,/photo.jpg/);assert.equal(page.nextCursor,null);
    assert.ok(!JSON.stringify(page).includes('private output'));
  }
});
test('visible-message pagination crosses tools without skipping or duplicating chat messages',async t=>{
  const rows=Array.from({length:127},(_,i)=>[
    {turnId:'t'+i,item:{type:'commandExecution',id:'tool'+i}},
    {turnId:'t'+i,item:{type:'agentMessage',id:'chat'+i,text:'reply '+i}}
  ]).flat();const g=await fixture(t,rows);let cursor;const ids=[];const counts=[];
  do {const page=await g.history('thread-history-123',cursor);counts.push(page.messages.filter(m=>m.role!=='tool').length);ids.push(...page.messages.filter(m=>m.role!=='tool').map(m=>m.id));cursor=page.nextCursor;}while(cursor);
  assert.deepEqual(counts,[50,50,27]);assert.equal(ids.length,new Set(ids).size);assert.equal(ids.length,127);
});
test('late unwatch from previous chat does not detach the newly selected chat',async t=>{
  const g=await fixture(t,[]),peer={id:'phone',emit:()=>{}};
  await g.handle('watch',{threadId:'thread-current-123'},peer);
  await g.handle('unwatch',{threadId:'thread-previous-123'},peer);
  assert.equal(g.subscribers.get(peer.id).threadId,'thread-current-123');
  await g.handle('unwatch',{threadId:'thread-current-123'},peer);assert.equal(g.subscribers.size,0);
});
test('live input carries a stable client identity before persisted photo message arrives',()=>{
  const [row]=messages([{turnId:'turn',params:{clientUserMessageId:'client',input:[{type:'text',text:'photo'},{type:'localImage',path:'D:/photo.jpg'}]},items:[]}]);
  assert.equal(row.clientMessageId,'client');assert.equal(row.provisional,true);assert.match(row.text,/photo.jpg/);
});

test('command summaries retain ordering time without sending command output until expanded',async t=>{
  const command={type:'commandExecution',id:'cmd',command:'printf hello',aggregatedOutput:'hello',status:'completed',exitCode:0};
  const g=await fixture(t,[]);g.states.set('thread-history-123',{state:{turns:[{turnId:'turn',items:[command]}]}});
  const rows=messages([{turnId:'turn',items:[{...command,startedAtMs:1234}]}],230000,true);
  assert.equal(rows[0].startedAtMs,1234);assert.equal(rows[0].role,'tool');assert.ok(!JSON.stringify(rows).includes('hello'));
  const details=await g.handle('commandDetails',{threadId:'thread-history-123',turnId:'turn',itemId:'cmd'},{});
  assert.equal(details.command,'printf hello');assert.equal(details.output,'hello');assert.equal(details.exitCode,0);
  g.states.set('thread-history-123',{state:{turns:[{turnId:'turn',items:[{type:'reasoning',id:'reason',text:'private'}]}]}});
  await assert.rejects(g.handle('commandDetails',{threadId:'thread-history-123',turnId:'turn',itemId:'reason'},{}));
});

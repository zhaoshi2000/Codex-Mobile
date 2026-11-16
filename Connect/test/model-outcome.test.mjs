import test from 'node:test';
import assert from 'node:assert/strict';
import {EventEmitter} from 'node:events';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import {Gateway} from '../src/gateway.mjs';
import {messages,turnOutcome} from '../src/timeline.mjs';

const failure = {message:'You’ve hit your usage limit. Try again at Nov 20th, 2026 5:56 PM.',codexErrorInfo:'usageLimitExceeded'};
const failedTurn = {turnId:'turn-failed',status:'failed',error:failure,params:{clientUserMessageId:'send-message'},items:[{id:'desktop-error',type:'error',message:failure.message,errorInfo:'usageLimitExceeded',willRetry:false}]};
test('failed quota turns retain the reason and retry time in live and persisted history',()=>{
 const live=messages([failedTurn]);
 const stored=messages([{id:failedTurn.turnId,items:failedTurn.items}]);
 assert.equal(live.length,1);assert.equal(live[0].role,'error');assert.deepEqual(live,stored);
 assert.match(live[0].text,/额度已达上限/);assert.match(live[0].text,/Nov 20th/);
 assert.equal(turnOutcome(failedTurn).status,'failed');assert.equal(turnOutcome(failedTurn).kind,'quota');
 assert.equal(turnOutcome({status:'inProgress'}),null);
 assert.equal(turnOutcome({status:'completed'}).status,'completed');
 assert.equal(turnOutcome({status:'interrupted'}).status,'interrupted');
 assert.equal(messages([{id:'retry',items:[{type:'error',message:'network retry',willRetry:true}]}]).length,0);
 assert.equal(turnOutcome({status:'failed',error:{message:'Network unavailable'}}).kind,'error');
});

async function fixture(t) {
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'astro-outcome-'));const calls=[];
 const ipc=new EventEmitter();Object.assign(ipc,{follow(){},owner:async()=> 'owner',modelSettings:async()=>({model:'alpha',reasoningEffort:'high'}),setModel:async(...args)=>{calls.push(args);return {model:args[1],reasoningEffort:args[2]};}});
 const rpc={call:async(method)=>{
  if(method==='thread/read')return {thread:{cwd:dir}};
  if(method==='model/list')return {data:[{model:'alpha',supportedReasoningEfforts:[{reasoningEffort:'low'},{reasoningEffort:'high'}],defaultReasoningEffort:'low'},{model:'beta',supportedReasoningEfforts:[{reasoningEffort:'medium'}],defaultReasoningEffort:'medium'}]};
  if(method==='thread/turns/list')return {data:[failedTurn]};
  // The real persistence API omits error items from thread/items/list.
  return {data:[{turnId:failedTurn.turnId,item:{id:'before-failure',type:'agentMessage',text:'Working…'}}]};
 }};
 const g=new Gateway({rpc,ipc,roots:[dir],stateDir:dir});await g.init();
 t.after(async()=>{await g.close();await fs.rm(dir,{recursive:true,force:true});});return {g,calls};
}
test('effort changes are validated against actual model support before touching desktop settings',async t=>{
 const {g,calls}=await fixture(t),threadId='thread-model-123',peer={id:'phone',publicKey:'key'};
 assert.equal((await g.handle('setModel',{threadId,model:'alpha',effort:'low'},peer)).current.reasoningEffort,'low');
 assert.equal((await g.handle('setModel',{threadId,model:'beta'},peer)).current.reasoningEffort,'medium');
 await assert.rejects(g.handle('setModel',{threadId,model:'alpha',effort:'ultra'},peer),/不支持/);
 await assert.rejects(g.handle('setModel',{threadId,model:'missing',effort:'low'},peer),/列表/);
 assert.equal(calls.length,2);
});
test('failed queued completions persist their outcome and history survives reconnect',async t=>{
 const {g}=await fixture(t);const threadId='thread-quota-123',events=[],peer={id:'phone',publicKey:'key',emit:e=>events.push(e)};
 g.subscribers.set(peer.id,{threadId,peer});g.ledger['send-message']={owner:'key',threadId,at:Date.now(),mode:'queued'};g.pendingQueued.set(threadId,new Set(['send-message']));
 await g.completeQueuedTurns(threadId,[failedTurn]);
 assert.equal(events[0].outcome.kind,'quota');
 const completions=await g.handle('completions',{},peer);assert.equal(completions.items[0].outcome.status,'failed');
 assert.equal((await g.handle('completions',{}, {publicKey:'other'})).items.length,0);
 const history=await g.history(threadId);assert.equal(history.outcome.kind,'quota');assert.match(history.messages.at(-1).text,/Nov 20th/);
});
test('instant quota failure ends monitored sending without falsely completing an older failed turn',async t=>{
 const {g}=await fixture(t);const threadId='thread-quota-123',events=[],peer={id:'phone',publicKey:'key',emit:e=>events.push(e)};
 g.subscribers.set(peer.id,{threadId,peer});g.ledger['send-message']={owner:'key',threadId,at:Date.now()};g.monitors.set(threadId,{messageId:'send-message',active:false});
 const snapshot=turn=>({method:'thread-stream-state-changed',version:13,params:{conversationId:threadId,change:{type:'snapshot',revision:1,conversationState:{turns:[turn],threadRuntimeStatus:{type:'idle'}}}}});
 g.onBroadcast(snapshot({...failedTurn,params:{clientUserMessageId:'older'}}));await new Promise(r=>setTimeout(r,350));
 assert.equal(events.filter(e=>e.event==='completed').length,0);
 g.onBroadcast(snapshot(failedTurn));await new Promise(r=>setTimeout(r,350));
 const done=events.find(e=>e.event==='completed');assert.equal(done.outcome.status,'failed');assert.equal(done.outcome.kind,'quota');
});

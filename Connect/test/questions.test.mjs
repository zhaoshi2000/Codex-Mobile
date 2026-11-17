import test from 'node:test'; import assert from 'node:assert/strict'; import { EventEmitter } from 'node:events'; import fs from 'node:fs/promises'; import os from 'node:os'; import path from 'node:path';
import { desktopTurns, applyChange, messages, progress } from '../src/timeline.mjs';
import { questionGroups, questionAnswer } from '../src/questions.mjs'; import { Gateway } from '../src/gateway.mjs'; import { DesktopIPC } from '../src/desktop.mjs';
function fixture() { const turn = { turnId:'turn-1',status:'inProgress',items:[{type:'agentMessage',id:'ask',questions:[{title:'选择环境',options:['测试','生产']}],text:''},{type:'agentMessage',id:'stream',text:'正在',phase:'commentary'},{type:'reasoning',id:'hidden',content:['private reasoning']} ]}; return { turns:[],threadRuntimeStatus:{type:'active'},turnHistory:{kind:'canonical',history:{entitiesByKey:{t:turn},islands:[{entries:[{key:'t',value:'t'}]}] }},requests:[] }; }
test('canonical Desktop history streams text, questions, and progress without reasoning', () => {
 const s=fixture();let state=applyChange(null,{type:'snapshot',revision:1,conversationState:s});
 state=applyChange(state,{type:'patches',baseRevision:1,revision:2,patches:[{op:'replace',path:['turnHistory','history','entitiesByKey','t','items',1,'text'],value:'正在实时输出'}]});
 const turns=desktopTurns(state.state);assert.equal(messages(turns).at(-1).text,'正在实时输出');assert.equal(progress(s).label,'正在思考…');assert.ok(!JSON.stringify(messages(turns)).includes('private reasoning'));
 const g=questionGroups(s,turns)[0];assert.equal(g.questions[0].id,'["request_user_input_async","ask",0]');
 const response=questionAnswer(g,{[g.questions[0].id]:'测试'});turns[0].items.push({type:'steeringUserMessage',id:'answer',status:'accepted',input:[{type:'text',text:response}]});assert.equal(questionGroups(state.state,turns).length,0);
 assert.throws(()=>questionAnswer(g,{}));
});
test('sync answers preserve numeric request ID and use the exact Desktop reply route', async()=>{
 const s=fixture();s.requests=[{id:36,method:'item/tool/requestUserInput',params:{questions:[{id:'q',question:'选择',options:[{label:'A',description:'说明'}]}]}}];
 const g=questionGroups(s,[])[0];const ipc=new DesktopIPC();ipc.owner=async()=> 'owner';let seen;ipc.request=async(...args)=>seen=args;
 await ipc.answer('thread',g,questionAnswer(g,{q:'A'}),'message',true);
 assert.equal(seen[0],'thread-follower-submit-user-input');assert.equal(seen[1].requestId,36);assert.deepEqual(seen[1].response,{answers:{q:{answers:['A']}}});assert.equal(seen[2],1);
 s.requests[0].completed=true;assert.equal(questionGroups(s,[]).length,0);
});
test('answers reject stale/foreign requests and uncertain delivery is never replayed',async t=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'ifile-answer-'));t.after(()=>fs.rm(dir,{recursive:true,force:true}));
 const ipc=new EventEmitter();Object.assign(ipc,{connected:true,follow(){},owner:async()=> 'owner'});let count=0;ipc.answer=async()=>{count++;throw Error('lost ack')};
 const g=new Gateway({ipc,rpc:{call:async()=>({thread:{cwd:dir}})},roots:[dir],stateDir:dir});await g.init();t.after(()=>g.close());
 const peer={id:'phone',publicKey:'key'};await g.handle('watch',{threadId:'thread-123456'},peer);const state=fixture();g.states.set('thread-123456',{state,revision:1});const group=questionGroups(state,desktopTurns(state))[0];
 const p={threadId:'thread-123456',groupId:group.id,messageId:'message-1234567890',answers:{[group.questions[0].id]:'测试'}};
 assert.equal((await g.handle('answerStatus',p,peer)).state,'notSubmitted');
 const [a,b]=await Promise.all([g.handle('answer',p,peer),g.handle('answer',p,peer)]);assert.equal(count,1);assert.equal(a.state,'unknown');assert.equal(b.state,'unknown');await assert.rejects(g.handle('answer',{...p,messageId:'different-message-123456'},peer));assert.equal(count,1);
 assert.equal((await g.handle('answerStatus',p,peer)).state,'unknown');assert.equal(count,1);
 await assert.rejects(g.handle('answerStatus',p,{id:'other',publicKey:'foreign'}));
 await assert.rejects(g.handle('answer',{...p,messageId:'message-1234567891',groupId:'stale'},peer));await assert.rejects(g.handle('answer',p,{id:'other',publicKey:'foreign'}));
});
test('explicit skipped answers reach the original question without selecting an option',()=>{
 const s=fixture(), turns=desktopTurns(s), group=questionGroups(s,turns)[0];
 const response=questionAnswer(group,{[group.questions[0].id]:'用户跳过此问题，未提供答案。'});
 assert.ok(!response.includes('"answer":"生产"'));
 turns[0].items.push({type:'steeringUserMessage',status:'accepted',input:[{type:'text',text:response}]});
 assert.equal(questionGroups(s,turns).length,0);
});

import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs/promises';import os from 'node:os';import path from 'node:path';import {EventEmitter} from 'node:events';import {randomUUID} from 'node:crypto';import {Gateway} from '../src/gateway.mjs';import {DesktopIPC} from '../src/desktop.mjs';import {DesktopCatalog} from '../src/catalog.mjs';
async function fixture(t, options={}){const dir=await fs.mkdtemp(path.join(os.tmpdir(),'astro-chat-test-'));const ipc=new EventEmitter();ipc.connected=true;ipc.owner=async()=> 'owner';ipc.follow=()=>{};const rpc={call:async()=>({thread:{cwd:dir}})};const g=new Gateway({rpc,ipc,stateDir:dir,roots:[dir],...options});await g.init();t.after(async()=>{await g.close();await fs.rm(dir,{recursive:true,force:true});});return{g,ipc,rpc,dir,peer:{id:'phone',publicKey:'key'},id:'thread-test-123456'};}

test('active messages queue natively; only explicit steering removes and sends once', async t => {
  const {g,ipc,peer,id}=await fixture(t); let queues=0,steers=0,starts=0,removes=0;
  ipc.queue=async()=>{queues++}; ipc.steer=async()=>{steers++}; ipc.send=async()=>{starts++}; ipc.removeQueued=async()=>{removes++;return {id:'removed'}};
  g.states.set(id,{state:{threadRuntimeStatus:{type:'active'}}});
  const p={threadId:id,text:'follow-up',messageId:randomUUID()};
  assert.equal((await g.handle('send',p,peer)).mode,'queued'); await g.handle('send',p,peer);
  assert.equal(queues,1); assert.equal(steers,0); assert.equal(starts,0);
  await assert.rejects(g.handle('steerQueued',p,{...peer,publicKey:'foreign'}));
  assert.equal((await g.handle('steerQueued',p,peer)).state,'accepted'); await g.handle('steerQueued',p,peer);
  assert.equal(steers,1);assert.equal(removes,1);
  g.states.set(id,{state:{threadRuntimeStatus:{type:'idle'}}});await g.handle('send',{...p,messageId:randomUUID()},peer);assert.equal(starts,1);
});
test('steering an already consumed queued message never sends it twice; timeout is never retried', async t => {
  const {g,ipc,peer,id}=await fixture(t);ipc.queue=async()=>{};g.states.set(id,{state:{threadRuntimeStatus:{type:'active'}}});
  const p={threadId:id,text:'follow-up',messageId:randomUUID()};await g.handle('send',p,peer);
  ipc.removeQueued=async()=>null;let sends=0;ipc.steer=async()=>{sends++;throw Error('lost reply')};
  await assert.rejects(g.handle('steerQueued',p,peer),/已发送/);assert.equal(sends,0);
  ipc.removeQueued=async()=>({id:p.messageId});assert.equal((await g.handle('steerQueued',p,peer)).state,'unknown');
  await g.handle('steerQueued',p,peer);assert.equal(sends,1);
});
test('native queue reserve/complete does not replace existing Desktop messages and preserves attachments', async()=>{
  const ipc=new DesktopIPC();ipc.owner=async()=> 'owner';const calls=[];ipc.request=async(...args)=>{calls.push(args);return{result:{ok:true}}};
  await ipc.queue('thread','hello','message',[{image:true,path:'C:/photo.jpg',name:'photo.jpg'},{image:false,path:'C:/note.md',name:'note.md'}],'C:/project');
  assert.equal(calls.length,2);for(const call of calls){assert.equal(call[2],3);assert.equal(call[1].preparationMessageId,'message');assert.equal(call[1].state.thread.length,1)}
  assert.ok(calls[0][1].state.thread[0].preparation);assert.equal(calls[1][1].state.thread[0].preparation,undefined);
  assert.equal(calls[1][1].state.thread[0].context.imageAttachments[0].localPath,'C:/photo.jpg');
  assert.equal(calls[1][1].state.thread[0].context.fileAttachments[0].path,'C:/note.md');
});

test('Desktop model/steer routes preserve attachments and only update model/effort',async()=>{const ipc=new DesktopIPC();ipc.owner=async()=> 'owner';let captured;ipc.request=async(method,params,version,owner)=>{captured={method,params,version,owner};return{result:method.includes('read-model')?{settings:{model:'model-b'}}:{applied:true}}};await ipc.steer('thread','hello','message',[{image:true,path:'C:/image.jpg'},{image:false,path:'C:/note.md',name:'note.md'}]);assert.equal(captured.version,1);assert.equal(captured.params.input[1].type,'localImage');assert.equal(captured.params.input[2].type,'mention');let update;ipc.request=async(method,params,version)=>{if(method.includes('update-thread')){update={params,version};return{result:{applied:true}}}return{result:{settings:{model:'model-b'}}}};assert.equal((await ipc.setModel('thread','model-b','high')).model,'model-b');assert.deepEqual(update.params.threadSettings,{model:'model-b',effort:'high'});assert.equal(update.version,2);});

test('green completion transitions persist blue unread per phone and viewing clears only that phone',async t=>{const{g,ipc,peer,id,dir}=await fixture(t,{desktopCatalog:true,codexHome:'unused'});g.activity.followed.add(id);g.activity.rows.set(id,{id,projectId:'project-1'});const snapshot=status=>ipc.emit('broadcast',{method:'thread-stream-state-changed',version:13,params:{conversationId:id,change:{type:'snapshot',revision:1,conversationState:{threadRuntimeStatus:{type:status}}}}});snapshot('active');assert.deepEqual(g.badges(peer).runningProjects,['project-1']);snapshot('idle');await g.navigationQueue;assert.deepEqual(g.badges(peer).unread,[id]);assert.deepEqual(g.badges(peer).unreadProjects,['project-1']);const stored=JSON.parse(await fs.readFile(path.join(dir,'navigation.json'),'utf8'));assert.ok(stored.completed[id]);assert.equal(stored.projects[id],'project-1');await g.handle('markRead',{threadId:id},peer);assert.deepEqual(g.badges(peer).unread,[]);assert.deepEqual(g.badges({publicKey:'second'}).unread,[id]);snapshot('active');snapshot('idle');assert.ok(g.completedThreads[id]);});

test('20 conversation pages use exact boundaries without duplicates or skipped rows',async t=>{const dir=await fs.mkdtemp(path.join(os.tmpdir(),'astro-pages-'));t.after(()=>fs.rm(dir,{recursive:true,force:true}));await fs.writeFile(path.join(dir,'.codex-global-state.json'),JSON.stringify({'local-projects':{p:{id:'p',name:'P',rootPaths:[dir]}}}));const source=Array.from({length:45},(_,i)=>({id:'thread-'+i,name:'Chat '+i,projectId:'p'}));const rpc={call:async(_,p)=>{const start=Number(p.cursor||0),end=start+p.limit;return{data:source.slice(start,end),nextCursor:end<source.length?String(end):null}}};const catalog=new DesktopCatalog({rpc,codexHome:dir});const a=await catalog.threads({limit:20}),b=await catalog.threads({limit:20,cursor:a.nextCursor}),c=await catalog.threads({limit:20,cursor:b.nextCursor});assert.deepEqual([a.threads.length,b.threads.length,c.threads.length],[20,20,5]);assert.equal(new Set([...a.threads,...b.threads,...c.threads].map(r=>r.id)).size,45);});

test('fork includes the selected completed turn, defers goals, deduplicates and rejects an active turn',async t=>{const{g,rpc,peer,id}=await fixture(t);let status='inProgress',forkParams,calls=0;rpc.call=async(method,p)=>{if(method==='thread/read')return{thread:{cwd:g.roots[0],name:'Original'}};if(method==='thread/turns/list')return{data:[{id:'turn-1',status}]};if(method==='thread/fork'){forkParams=p;calls++;return{thread:{id:'fork-thread-123'}}}return{}};const p={threadId:id,turnId:'turn-1',requestId:randomUUID()};await assert.rejects(g.handle('forkThread',p,peer),/尚未结束/);status='completed';const a=await g.handle('forkThread',p,peer),b=await g.handle('forkThread',p,peer);assert.deepEqual(a,b);assert.equal(calls,1);assert.equal(forkParams.lastTurnId,'turn-1');assert.equal(forkParams.deferGoalContinuation,true);await assert.rejects(g.handle('forkThread',p,{...peer,publicKey:'other'}));});

test('thumbnail is cropped, bounded, cached, and reauthorizes paths on every request',async t=>{
 const{g,peer,dir}=await fixture(t);const{default:sharp}=await import('sharp');const image=path.join(dir,'portrait.png');
 await sharp({create:{width:400,height:800,channels:3,background:'#4488aa'}}).png().toFile(image);
 const p={projectId:'0',absolutePath:image};const a=await g.handle('imageThumbnail',p,peer);
 const bytes=Buffer.from(a.data,'base64');const info=await sharp(bytes).metadata();assert.equal(info.width,240);assert.equal(info.height,240);assert.ok(bytes.length<150000);
 assert.deepEqual(await g.handle('imageThumbnail',p,peer),a);
 await assert.rejects(g.handle('imageThumbnail',{...p,absolutePath:path.join(dir,'..','outside.png')},peer));
});

test('queued completion follows its actual turn, not the preceding task, and survives phone unwatch',async t=>{
 const{g,ipc,peer,id}=await fixture(t);ipc.queue=async()=>{};g.states.set(id,{state:{threadRuntimeStatus:{type:'active'}}});
 g.monitors.set(id,{messageId:'previous',active:true});const messageId=randomUUID();await g.handle('send',{threadId:id,messageId,text:'later'},peer);
 assert.equal(g.monitors.get(id).messageId,'previous');assert.ok(g.pendingQueued.get(id).has(messageId));
 g.monitors.clear();g.subscribers.set(peer.id,{threadId:id,peer});g.unwatch(peer.id);assert.ok(g.states.has(id));
 await g.completeQueuedTurns(id,[{id:'previous-turn',status:'completed',items:[]}]);assert.equal(g.ledger[messageId].completedAt,undefined);
 await g.completeQueuedTurns(id,[{id:'later-turn',status:'inProgress',params:{clientUserMessageId:messageId}}]);assert.equal(g.ledger[messageId].startedTurnId,'later-turn');
 await g.completeQueuedTurns(id,[{id:'later-turn',status:'completed',items:[]}]);assert.ok(g.ledger[messageId].completedAt);assert.equal(g.pendingQueued.has(id),false);
});

test('rename uses native thread name, rejects invalid titles, and reports failure without notifying phones', async t => {
  const {g,rpc,peer,id}=await fixture(t);let name='old',events=[];
  g.subscribers.set(peer.id,{threadId:id,peer:{...peer,emit:e=>events.push(e)}});
  rpc.call=async(method,p)=>{if(method==='thread/read')return{thread:{cwd:g.roots[0]}};assert.equal(method,'thread/name/set');if(p.name==='reject')throw Error('desktop rejected');name=p.name;return{}};
  assert.equal((await g.handle('renameThread',{threadId:id,title:'  新标题  '},peer)).title,'新标题');
  assert.equal(name,'新标题');assert.equal(events[0].title,'新标题');
  for(const title of ['', 'x'.repeat(121), 'a\nb'])await assert.rejects(g.handle('renameThread',{threadId:id,title},peer));
  await assert.rejects(g.handle('renameThread',{threadId:id,title:'reject'},peer));assert.equal(events.length,1);
});

test('queued steering display preserves attachment links and hides stale queue rows after dispatch',async t=>{
 const {g,peer,id}=await fixture(t);const mid=randomUUID();
 g.ledger[mid]={owner:peer.publicKey,text:'follow up',attachments:[{name:'photo.jpg',path:'C:/project/photo.jpg',image:true}]};
 g.queued.set(id,[{id:mid,text:'follow up'}]);
 const row=(await g.queueRows(id,peer))[0];assert.equal(row.displayText,'follow up\n📎 [photo.jpg](<C:/project/photo.jpg>)');assert.equal(row.editable,true);
 const other=(await g.queueRows(id,{publicKey:'another'}))[0];assert.equal(other.displayText,'follow up');assert.equal(other.editable,false);
 g.ledger[mid].queueAction='steerQueued';assert.deepEqual(await g.queueRows(id,peer),[]);
});

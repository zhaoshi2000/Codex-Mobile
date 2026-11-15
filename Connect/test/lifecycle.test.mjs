import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {EventEmitter} from 'node:events';
import {randomUUID} from 'node:crypto';
import {Gateway} from '../src/gateway.mjs';

test('downloads allow exact assistant-linked external files, not user links, siblings, or directories', async t => {
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'astro-access-'));const root=path.join(dir,'project');await fs.mkdir(root);
 const external=path.join(dir,'export with spaces.md'),secret=path.join(dir,'unlinked.txt');await fs.writeFile(external,'export');await fs.writeFile(secret,'unlinked');
 const id='thread-test-123456';let items=[{type:'agentMessage',text:`[download](<${external}:12>)`},{type:'userMessage',text:`[file](<${secret}>)`}];let calls=0;
 const rpc={call:async m=>m==='thread/read'?{thread:{cwd:root}}:{data:items.map(item=>({item})),nextCursor:null}};
 const g=new Gateway({rpc,ipc:new EventEmitter(),stateDir:dir});await g.init();g.catalog={};t.after(async()=>{await g.close();await fs.rm(dir,{recursive:true,force:true});});const peer={id:'p',publicKey:'key'};
 const prepare=p=>g.handle('filePrepare',{projectId:'thread:'+id,absolutePath:p},peer);
 const lease=await prepare(external+':12');assert.equal(lease.name,path.basename(external));
 const chunk=await g.handle('fileChunk',{fileId:lease.id,offset:0},peer);assert.equal(Buffer.from(chunk.data,'base64').toString(),'export');
 await assert.rejects(prepare(secret),/不是此对话/);await assert.rejects(prepare(dir),/不是此对话/);
 await assert.rejects(g.handle('files',{projectId:'thread:'+id,relativePath:'..'},peer));
 items=[];await assert.rejects(prepare(external),/不是此对话/);
});

test('create retries return the original thread and retain project identity without duplicate creation',async t=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'astro-create-'));let starts=0;let startParams;
 const rpc={call:async(m,p)=>{if(m==='project/read')return{project:{id:p.projectId}};if(m==='thread/start'){starts++;startParams=p;return{thread:{id:'created-thread-123'}};}return{};}};
 const ipc=new EventEmitter();const g=new Gateway({rpc,ipc,stateDir:dir});await g.init();g.catalog={projects:[{id:'local',roots:[dir]}],appToLocal:new Map([['server','local']]),refresh:async()=>{},pages:new Map()};t.after(async()=>{await g.close();await fs.rm(dir,{recursive:true,force:true});});
 const p={projectId:'local',title:'title',requestId:randomUUID()},peer={id:'p',publicKey:'key'};
 const [a,b]=await Promise.all([g.handle('createThread',p,peer),g.handle('createThread',p,peer)]);assert.equal(starts,1);assert.deepEqual(a,b);assert.equal(startParams.projectId,'server');
 await assert.rejects(g.handle('createThread',p,{...peer,publicKey:'other'}),/冲突/);
 await assert.rejects(g.handle('createThread',{...p,title:'changed'},peer),/冲突/);
 const outside=await g.handle('createThread',{requestId:randomUUID()},peer);assert.equal(startParams.projectId,null);assert.ok(startParams.cwd.startsWith(path.join(dir,'conversations')));
});

test('creation with lost acknowledgement never silently starts another thread',async t=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'astro-create-'));let starts=0;const rpc={call:async()=>{starts++;throw Error('timeout');}};const g=new Gateway({rpc,ipc:new EventEmitter(),stateDir:dir});await g.init();g.catalog={refresh:async()=>{}};t.after(async()=>{await g.close();await fs.rm(dir,{recursive:true,force:true});});const p={requestId:randomUUID()},peer={id:'p',publicKey:'key'};await assert.rejects(g.handle('createThread',p,peer));await assert.rejects(g.handle('createThread',p,peer),/待核实/);assert.equal(starts,1);
});

test('delete requires explicit confirmation, rejects live tasks and deduplicates successful deletion',async t=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'astro-delete-'));const ipc=new EventEmitter();ipc.connected=true;ipc.owner=async()=>true;let status='active',deletes=0;
 ipc.follow=id=>queueMicrotask(()=>ipc.emit('broadcast',{method:'thread-stream-state-changed',version:13,params:{conversationId:id,change:{type:'snapshot',conversationState:{threadRuntimeStatus:{type:status},requests:[]}}}}));
 const rpc={call:async m=>{if(m==='thread/delete'){deletes++;return{};}return{thread:{cwd:dir}};}};
 const g=new Gateway({rpc,ipc,roots:[dir],stateDir:dir});await g.init();t.after(async()=>{await g.close();await fs.rm(dir,{recursive:true,force:true});});
 const p={threadId:'thread-test-123456',requestId:randomUUID(),confirm:true},peer={id:'p',publicKey:'key'};
 await assert.rejects(g.handle('deleteThread',{...p,confirm:false},peer),/确认/);await assert.rejects(g.handle('deleteThread',p,peer),/正在运行/);assert.equal(deletes,0);
 status='idle';await g.handle('deleteThread',p,peer);await g.handle('deleteThread',p,peer);assert.equal(deletes,1);await assert.rejects(g.handle('deleteThread',p,{...peer,publicKey:'other'}),/冲突/);
});

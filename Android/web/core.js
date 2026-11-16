/* Shared pure presentation logic. Also exercised by node:test. */
(function(root){
  const uuid=()=>globalThis.crypto.randomUUID();
  const escape=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  function merge(existing,incoming,{history=false}={}){
    const out=existing.slice(),keys=m=>[m.id,m.clientMessageId&&'client:'+m.clientMessageId,m.provisional&&m.turnId&&'turn:'+m.turnId].filter(Boolean);
    let cursor=-1;
    for(const item of incoming){
      const index=out.findIndex(m=>keys(m).some(k=>keys(item).includes(k))||(m.provisional&&m.turnId===item.turnId&&m.role==='user'&&item.role==='user'));
      if(index>=0){const old=out[index];out[index]=history&&!old.provisional&&old.live?{...item,...old,completedAtMs:item.completedAtMs||old.completedAtMs}:{...old,...item,pending:!!item.pending,live:!history};cursor=index;}
      else {let pos=cursor+1;if(cursor<0){const next=incoming.slice(incoming.indexOf(item)+1).find(n=>out.some(m=>m.id===n.id));pos=next?out.findIndex(m=>m.id===next.id):out.length;}
        out.splice(pos,0,{...item,live:!history});cursor=pos;}
    }
    // Acknowledged mobile messages replace their optimistic row, not a second bubble.
    const seen=new Set();return out.filter(m=>{const k=m.clientMessageId&&m.role==='user'?'client:'+m.clientMessageId:m.id;if(seen.has(k))return false;seen.add(k);return true;}).slice(-300);
  }
  function attachments(text){const images=[];let clean=String(text||'').replace(/(?:📎\s*)?\[([^\]]+)\]\(<?([^>\n]+?)>?\)/g,(all,name,path)=>{
    if(/\.(png|jpe?g|gif|webp|heic|bmp)$/i.test(path)&&!/^https?:/i.test(path)){images.push({name,path});return ''; }return all;
  });return {text:clean.trim(),images};}
  function groups(messages){const out=[];for(const m of messages){const last=out.at(-1);if(m.role==='user'){out.push({type:'user',messages:[m],key:m.id});continue;}if(last?.type==='assistant'&&last.turnId===m.turnId)last.messages.push(m);else out.push({type:'assistant',turnId:m.turnId,messages:[m],key:m.id});}return out;}
  function commands(messages){const out=[];for(const m of messages){if(m.role==='tool'&&out.at(-1)?.type==='commands')out.at(-1).messages.push(m);else out.push({type:m.role==='tool'?'commands':'text',messages:[m]});}return out;}
  function localLink(href){try{href=decodeURIComponent(href);}catch{}if(/^file:\/\//i.test(href))href=href.replace(/^file:\/\//i,'');return /^[a-z]:[\\/]/i.test(href)||href.startsWith('/')||(!/^[\w+.-]+:/.test(href)&&!href.startsWith('#'));}
  const api={uuid,escape,merge,attachments,groups,commands,localLink};root.Core=api;if(typeof module!=='undefined')module.exports=api;
})(globalThis);

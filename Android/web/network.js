// Network controls and durable question submission, compiled together with app.js.
const SKIPPED_ANSWER='用户跳过此问题，未提供答案。';
function questionKey(g){return s.device?.hostId+'|'+s.thread?.id+'|'+g.id;}
function questionRecord(g){s.qstates??={};return s.qstates[questionKey(g)]||{};}
function renderQuestions(){
 const el=$('#questions');if(!el)return;
 el.innerHTML=s.questions.map(g=>{
  const key=questionKey(g),state=questionRecord(g);s.qstates??={};
  if(!s.qstates[key]){s.qstates[key]={loading:true};call('questionState',{threadId:s.thread.id,groupId:g.id}).then(r=>{s.qstates[key]=r||{};if(questionKey(g)===key){s.answers??={};if(r.answers)s.answers[g.id]=r.answers;renderQuestions();}}).catch(e=>{s.qstates[key]={error:e.message};renderQuestions();});}
  const locked=s.qstates[key]?.loading||state.sending||['unknown','accepted'].includes(state.state),answers=s.answers?.[g.id]||{};
  return `<div class="questions" data-group="${E(g.id)}"><strong>需要你的回答</strong>${g.questions.map((q,i)=>`<p>${E(q.title)}</p>${q.options.map(o=>`<button class="questionoption ${answers[q.id]===o.label?'selected':''}" data-action="answerOption" data-question="${i}" data-value="${E(o.label)}" ${locked?'disabled':''}>${answers[q.id]===o.label?'●':'○'} ${E(o.label)}${o.description?`<small>${E(o.description)}</small>`:''}</button>`).join('')}<div class="row questiontools"><button data-action="customAnswer" data-question="${i}" ${locked?'disabled':''}>自定义回答</button><button data-action="skipAnswer" data-question="${i}" ${locked?'disabled':''}>${answers[q.id]===SKIPPED_ANSWER?'已跳过 · 撤销':'跳过此题'}</button></div><input type="${q.secret?'password':'text'}" data-answer="${i}" placeholder="填写回答" value="${E(answers[q.id]||'')}" ${locked?'disabled':''} ${q.options.length&&!s.customAnswers?.has(key+'|'+i)?'hidden':''}>`).join('')}<p class="hint">${E(state.error||(!s.connected?'电脑未连接':state.state==='accepted'?'已提交到电脑原对话':state.state==='unknown'?'送达待确认，核实状态不会重复发送':'选择、填写回答，或跳过暂不回答的问题'))}</p>${state.state==='accepted'?'':`<div class="row questiontools">${state.state==='unknown'?`<button class="primary" data-action="answerStatus" data-group="${E(g.id)}" ${state.sending||!s.connected?'disabled':''}>核实提交状态</button>`:`<button data-action="skipAllAnswers" data-group="${E(g.id)}" ${locked||!s.connected?'disabled':''}>跳过全部</button><button class="primary" data-action="answer" data-group="${E(g.id)}" ${locked||!s.connected||g.questions.some(q=>!(answers[q.id]||'').trim())?'disabled':''}>提交回答</button>`}</div>`}</div>`;
 }).join('')+(s.awaitingApproval?'<p class="hint">电脑权限审批需在桌面确认。</p>':'');
 el.oninput=e=>{const box=e.target.closest('[data-group]');if(!box||!e.target.hasAttribute('data-answer'))return;const g=s.questions.find(g=>g.id===box.dataset.group);s.answers??={};s.answers[g.id]??={};s.answers[g.id][g.questions[+e.target.dataset.answer].id]=e.target.value;const button=box.querySelector('[data-action=answer]');if(button)button.disabled=!s.connected||g.questions.some(q=>!(s.answers[g.id][q.id]||'').trim());};
}
async function submitQuestion(g,status=false){
 const key=questionKey(g),state=questionRecord(g);if(state.sending)return;
 state.sending=true;renderQuestions();
 try{s.qstates[key]=await call(status?'questionStatus':'questionSubmit',{threadId:s.thread.id,groupId:g.id,answers:s.answers?.[g.id]||{}});}
 catch(e){s.qstates[key]={...state,state:'unknown',sending:false,error:e.message};}
 finally{renderQuestions();}
}
function renderZeroTier(){
 const z=s.zeroTier||s.boot.zeroTier||{};header('ZeroTier',btn('servicesHome','back','返回服务'));
 showPage(`<div class="card"><strong>手机内置网络</strong><p class="hint">无需安装其他 ZeroTier App。只为 AstroGate 的文件和网页提供网络连接。</p>${field('networkID','网络 ID',z.networkID||'')}<button class="primary" data-action="toggleZeroTier" ${s.ztChanging?'disabled':''}>${s.ztChanging?'正在切换…':z.enabled?'关闭网络':'启用网络'}</button></div><div class="card"><strong id="ztStatus">${E(z.status||'已关闭')}</strong><p>节点 ID：<span id="ztNode">${E(z.nodeID||'尚未生成')}</span> <button data-action="copyNode">复制</button></p><p>网络 IP：<span id="ztAddress">${E(z.address||'等待分配')}</span></p><p class="hint">首次加入私有网络，需要在你的 ZeroTier 管理后台授权上面的节点 ID。</p></div><button data-action="ztLicense">开源许可</button>`);
 $('[name=networkID]').disabled=!!z.enabled||!!s.ztChanging;
}
async function updateZeroTier(){if(s.tab!=='services'||s.route!=='zerotier')return;s.zeroTier=await call('zeroTierState');for(const [id,value]of[['ztStatus',s.zeroTier.status],['ztNode',s.zeroTier.nodeID||'尚未生成'],['ztAddress',s.zeroTier.address||'等待分配']])if($('#'+id))$('#'+id).textContent=value;}
function hostServiceLink(href){try{const u=new URL(href);return /^https?:$/.test(u.protocol)&&(/^(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])$/.test(u.hostname)||/^10\./.test(u.hostname)||/^192\.168\./.test(u.hostname)||/^172\.(1[6-9]|2\d|3[01])\./.test(u.hostname));}catch{return false;}}
async function chooseDownload(params){const v=await modal('下载文件','<p>选择传输通道。直连需要手机与电脑加入同一个 ZeroTier 网络。</p>',[['取消',false],['服务器中转','relay'],['ZeroTier 直连','direct']]);if(v)await call('download',{...params,direct:v.__choice==='direct'});}
async function hostWeb(address='http://localhost:3000'){
 const v=await modal('主机网页服务',`<label>已配对电脑</label><select name="device">${s.boot.devices.map(d=>`<option value="${E(d.hostId)}" ${s.device?.hostId===d.hostId?'selected':''}>${E(deviceName(d))}</option>`).join('')}</select>${field('url','网页地址',address,'url')}${field('host','主机 ZeroTier IP（直连使用）',s.hostIP||'')}<p class="hint">保留网页地址的端口和路径。中转访问所选电脑的本机服务；直连服务需要监听其 ZeroTier 网卡。</p>`,[['取消',false],['服务器中转','relay'],['ZeroTier 直连','direct']]);
 if(!v)return;if(!v.device)throw Error('请先绑定电脑');
 const u=new URL(v.url);if(!/^https?:$/.test(u.protocol)||u.username||u.password)throw Error('请输入有效的 HTTP 或 HTTPS 地址');
 if(s.device?.hostId!==v.device||!s.connected)await connect(v.device);
 if(v.__choice==='direct'&&!v.host){const n=await rpc('networkInfo');v.host=n.zeroTierAddresses?.[0]||'';}
 if(v.__choice==='direct'&&!v.host)throw Error('电脑未报告 ZeroTier IP，请手动填写');
 s.hostIP=v.host;await call('hostWeb',{url:v.url,direct:v.__choice==='direct',host:v.host});
}
async function modelPicker(){
 const thread=s.thread.id,host=s.device.hostId,r=await rpc('models',{threadId:thread});
 if(s.thread?.id!==thread||s.device?.hostId!==host)return;
 s.models=r.models||[];s.model=r.current?.model;s.effort=r.current?.reasoningEffort||'';
 const v=await modal('选择模型',`<label>当前模型</label><select name="model">${s.models.map(m=>`<option value="${E(m.id)}" ${m.id===s.model?'selected':''}>${E(m.name||m.id)}</option>`).join('')}</select><p class="hint">思考强度在输入框旁调整。新模型用于后续轮次。</p>`);
 if(v&&s.thread?.id===thread&&s.device?.hostId===host){const result=await rpc('setModel',{threadId:thread,model:v.model});if(s.thread?.id!==thread||s.device?.hostId!==host)return;s.model=result.current?.model||v.model;s.effort=result.current?.reasoningEffort||'';renderStatus();}
}
let effortPanel=null;
const effortTitle=e=>({none:'不推理',minimal:'最少',low:'低',medium:'中',high:'高',xhigh:'更高',max:'最高',ultra:'极高'})[e]||e||'模型默认';
function closeEffort(){effortPanel=null;$('#effortPanel')?.remove();const send=$('#composer .send');if(send)send.disabled=s.uploading||!s.connected;}
function positionEffort(){const p=$('#effortPanel');if(p){const r=$('#composer').getBoundingClientRect();p.style.bottom=Math.max(8,innerHeight-r.top+8)+'px';}}
function renderEffort(){
 const p=effortPanel;if(!p)return;
 if(s.route!=='chat'||s.tab!=='codex'||s.thread?.id!==p.thread||s.device?.hostId!==p.host){closeEffort();return;}
 let box=$('#effortPanel');if(!box){box=document.createElement('section');box.id='effortPanel';document.body.append(box);}
 const send=$('#composer .send');if(send)send.disabled=p.busy||s.uploading||!s.connected;
 box.setAttribute('aria-label','思考强度');
 box.innerHTML=`<div class="row"><small class="grow">思考强度</small>${btn('closeEffort','close','关闭思考强度',p.busy?'disabled':'')}</div>${p.loading?'<p class="hint">正在读取可用档位…</p>':p.efforts.length?`<strong id="effortValue">${E(effortTitle(p.efforts[p.index]))}</strong><div id="effortTrack" role="slider" tabindex="0" aria-label="思考强度" aria-valuemin="0" aria-valuemax="${p.efforts.length-1}" aria-valuenow="${p.index}" aria-valuetext="${E(effortTitle(p.efforts[p.index]))}" aria-disabled="${!!p.busy}"><div class="effortFill"></div>${p.efforts.map((e,i)=>`<i style="left:calc(24px + (100% - 48px) * ${i/Math.max(1,p.efforts.length-1)})"></i>`).join('')}<span class="effortThumb"></span></div><p class="hint">${p.busy?'正在同步到电脑…':s.busy?'下一轮生效':'滑动或点选档位，下一条消息生效'}</p>`:'<p class="hint">当前模型未提供可调整的思考强度</p><button data-action="retryEffort">重新读取</button>'}${p.error?`<p class="error">${E(p.error)}</p>`:''}`;
 const track=$('#effortTrack');
 if(track){
  const update=e=>{const rect=track.getBoundingClientRect();p.index=Math.max(0,Math.min(p.efforts.length-1,Math.round((e.clientX-rect.left-24)/Math.max(1,rect.width-48)*(p.efforts.length-1))));paintEffort();};
  track.onpointerdown=e=>{if(p.busy||!s.connected)return;e.preventDefault();p.pointer=e.pointerId;track.setPointerCapture(e.pointerId);update(e);};
  track.onpointermove=e=>{if(p.pointer===e.pointerId)update(e);};
  track.onpointerup=e=>{if(p.pointer!==e.pointerId)return;p.pointer=null;safe(()=>saveEffort(p));};
  track.onpointercancel=()=>{p.pointer=null;};
  track.onkeydown=e=>{if(p.busy||!['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(e.key))return;e.preventDefault();p.index=Math.max(0,Math.min(p.efforts.length-1,p.index+(['ArrowRight','ArrowUp'].includes(e.key)?1:-1)));paintEffort();safe(()=>saveEffort(p));};
 }
 paintEffort();positionEffort();
}
function paintEffort(){const p=effortPanel,t=$('#effortTrack');if(!p||!t)return;const v=effortTitle(p.efforts[p.index]);t.style.setProperty('--position',p.index/Math.max(1,p.efforts.length-1));t.setAttribute('aria-valuenow',p.index);t.setAttribute('aria-valuetext',v);$('#effortValue').textContent=v;}
async function openEffort(){
 if(!s.connected||!s.writable||effortPanel?.busy)return;
 if(effortPanel&&!effortPanel.error){closeEffort();return;}
 const p={thread:s.thread.id,host:s.device.hostId,loading:true,busy:false,efforts:[],index:0};effortPanel=p;renderEffort();
 try{const r=await rpc('models',{threadId:p.thread});if(effortPanel!==p||s.thread?.id!==p.thread||s.device?.hostId!==p.host)return;
 s.models=r.models||[];s.model=r.current?.model;s.effort=r.current?.reasoningEffort||'';p.model=s.model;
 const m=s.models.find(m=>m.id===p.model);p.efforts=[...new Set((m?.efforts||[]).map(e=>e.reasoningEffort).filter(Boolean))];p.current=s.effort||m?.defaultEffort||'';p.index=Math.max(0,p.efforts.indexOf(p.current));
 }catch(e){p.error=e.message;}finally{p.loading=false;if(effortPanel===p)renderEffort();}
}
async function saveEffort(p){
 if(effortPanel!==p||p.busy||!s.connected||!s.writable)return;
 if(s.thread?.id!==p.thread||s.device?.hostId!==p.host){closeEffort();return;}
 if(s.model!==p.model){p.error='模型已变更，请重新读取档位';p.efforts=[];renderEffort();return;}
 const effort=p.efforts[p.index];if(!effort)return;if(effort===p.current){closeEffort();return;}
 p.busy=true;p.error=null;renderEffort();
 try{const r=await rpc('setModel',{threadId:p.thread,model:p.model,effort});if(effortPanel!==p||s.thread?.id!==p.thread||s.device?.hostId!==p.host)return;s.model=r.current?.model||p.model;s.effort=r.current?.reasoningEffort||effort;closeEffort();renderStatus();}
 catch(e){p.error='未能切换：'+e.message;}
 finally{p.busy=false;if(effortPanel===p)renderEffort();}
}
// Pointer controls preserve the draft's keyboard; keyboard navigation remains available.
document.addEventListener('pointerdown',e=>{
 if(e.target.closest('[data-action=effort],#effortPanel')){if(!e.target.closest('#effortTrack'))e.preventDefault();return;}
 if(effortPanel&&!effortPanel.busy)closeEffort();
});
window.addEventListener('resize',positionEffort);window.visualViewport?.addEventListener('resize',positionEffort);
let previewSequence=0,previewGallery=[],previewIndex=0;const originalImages=new Map();
async function previewImage(photo,photos=[photo],index=0){
 previewGallery=photos;previewIndex=index;const token=++previewSequence;
 const frame=content=>`<div class="imagewindow"><div class="row"><span class="grow ellipsis">${E(photo.name)}</span>${btn('closePreview','close','关闭图片')}</div>${content}${photos.length>1?`<div class="row imagecontrols">${btn('previousImage','back','上一张',index===0?'disabled':'')}<small>${index+1} / ${photos.length}</small><button data-action="nextImage" aria-label="下一张" ${index===photos.length-1?'disabled':''}>›</button></div>`:''}</div>`;
 $('#preview').hidden=false;$('#preview').innerHTML=frame('<p>正在读取原图…</p>');
 const key=s.device?.hostId+'|'+s.thread?.id+'|'+photo.path;
 if(!originalImages.has(key)){originalImages.set(key,(async()=>{const file=await call('download',{...fileParams(photo.path),preview:true});const src=await call('localImage',{path:file.path});return {file,src};})());if(originalImages.size>20)originalImages.delete(originalImages.keys().next().value);}
 try{const {file,src}=await originalImages.get(key);if(token===previewSequence&&!$('#preview').hidden)$('#preview').innerHTML=frame(`<img src="${src}" alt="${E(photo.name)}"><button data-action="sharePreview" data-path="${E(file.path)}">分享原图</button>`);}catch(e){originalImages.delete(key);if(token===previewSequence)$('#preview').innerHTML=frame(`<p>${E(e.message)}</p>`);}
}
setInterval(()=>safe(updateZeroTier),2000);

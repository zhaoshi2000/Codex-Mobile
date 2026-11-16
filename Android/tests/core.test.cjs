const {test}=require('node:test');const assert=require('node:assert/strict');
const C=require('../app/src/main/assets/core.js');
test('reentry history preserves streaming output and inserts missing messages in order',()=>{
 const old=[{id:'a',role:'assistant',text:'完整实时回复',live:true},{id:'c',role:'user',text:'下一条'}];
 const result=C.merge(old,[{id:'previous',role:'user',text:'此前的问题'},{id:'a',role:'assistant',text:'截断'},{id:'b',role:'assistant',text:'下载链接'}],{history:true});
 assert.deepEqual(result.map(x=>x.id),['previous','a','b','c']);assert.equal(result[1].text,'完整实时回复');
});
test('steered local message is replaced by desktop acknowledgement',()=>{
 const r=C.merge([{id:'phone',role:'user',clientMessageId:'request1',text:'引导内容',pending:true,provisional:true}],[{id:'desktop',role:'user',clientMessageId:'request1',text:'引导内容'}]);
 assert.equal(r.length,1);assert.equal(r[0].id,'desktop');
});
test('photo extraction retains document downloads and handles Windows paths with spaces',()=>{
 const r=C.attachments('问题\n📎 [照片](<D:/a b/image.jpg>)\n📎 [报告](<D:/reports/报告.pdf>)');assert.equal(r.images[0].path,'D:/a b/image.jpg');assert.match(r.text,/报告.pdf/);assert.equal(r.images.length,1);
});
test('commands collapse only adjacent tools within a turn',()=>{
 const g=C.groups([{id:'u',role:'user'},{id:'a',role:'assistant',turnId:'t'},{id:'b',role:'tool',turnId:'t'},{id:'c',role:'tool',turnId:'t'},{id:'d',role:'assistant',turnId:'t'}]);
 assert.equal(g.length,2);const rows=C.commands(g[1].messages);assert.equal(rows.length,3);assert.equal(rows[1].messages.length,2);
});
test('markup and unknown schemes cannot become executable local links',()=>{assert.equal(C.escape('<img onerror="x">'),'&lt;img onerror=&quot;x&quot;&gt;');assert.equal(C.localLink('javascript:alert(1)'),false);assert.equal(C.localLink('D:/报告.pdf'),true);assert.equal(C.localLink('https://example.com/file.pdf'),false);});

import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs/promises';import os from 'node:os';import path from 'node:path';import {matchesLinkedFile} from '../src/download-access.mjs';
test('native user attachments outside cwd can be previewed without authorizing user typed paths or sibling files',async()=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'astro-external-image-'));const file=path.join(dir,'image.jpg');await fs.writeFile(file,'image');
 try{const items=[{type:'userMessage',content:[{type:'localImage',path:file}]}];assert.equal(await matchesLinkedFile(file,items),await fs.realpath(file));assert.equal(await matchesLinkedFile(path.join(dir,'other.jpg'),items),null);assert.equal(await matchesLinkedFile(file,[{type:'userMessage',content:[{type:'text',text:`[image](<${file}>)`}]}]),null);}finally{await fs.rm(dir,{recursive:true,force:true});}
});

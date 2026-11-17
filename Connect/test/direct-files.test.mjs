import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { DirectFiles } from '../src/direct-files.mjs';

test('direct download requires live capability and cannot escape snapshot', async()=>{
  const dir=await fs.mkdtemp(path.join(os.tmpdir(),'direct-test-'));
  const file=path.join(dir,'snapshot'); await fs.writeFile(file,'snapshot');
  const lease={file,size:8,expires:Date.now()+60000}, leases=new Map([['id',lease]]);
  const direct=new DirectFiles(leases,()=>['127.0.0.1']);
  try {
    const link=await direct.link(lease), origin=`http://${link.host}:${link.port}`;
    assert.equal(await (await fetch(origin+link.path)).text(),'snapshot');
    assert.equal((await fetch(origin+'/etc/passwd')).status,404);
    assert.equal((await fetch(origin+'/'+ 'a'.repeat(64))).status,404);
    lease.expires=0; assert.equal((await fetch(origin+link.path)).status,404);
    lease.expires=Date.now()+60000; leases.clear();
    assert.equal((await fetch(origin+link.path)).status,404);
  } finally {await direct.close();await fs.rm(dir,{recursive:true,force:true});}
});

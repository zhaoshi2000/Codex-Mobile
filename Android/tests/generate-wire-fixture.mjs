import {createPrivateKey,createPublicKey} from 'node:crypto';
import {sessionKey,SecureSession} from '../../Connect/src/crypto.mjs';
import fs from 'node:fs/promises';
// Public deterministic test identities. Never used as actual device identities.
const identity=n=>{const der=Buffer.concat([Buffer.from('302e020100300506032b656e04220420','hex'),Buffer.alloc(32,n)]);return createPrivateKey({key:der,format:'der',type:'pkcs8'}).export({format:'jwk'});};
const phone=identity(1),host=identity(2),hostId='test-host',sid='test-session|challenge';
const key=sessionKey(host,phone.x,hostId,sid),wire=new SecureSession(key,hostId,sid,'h2c');
const fixture={phoneSecret:phone.d,hostPublic:host.x,phonePublic:phone.x,key:key.toString('base64'),hostId,sid,boxes:[wire.seal({event:'ready',text:'跨端加密测试'}),wire.seal({id:'request',result:{alive:true}})]};
await fs.mkdir(new URL('../app/src/test/resources/',import.meta.url),{recursive:true});await fs.writeFile(new URL('../app/src/test/resources/wire.json',import.meta.url),JSON.stringify(fixture));

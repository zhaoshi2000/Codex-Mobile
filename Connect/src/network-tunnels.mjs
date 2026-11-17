import net from 'node:net';
import os from 'node:os';
import { randomUUID } from 'node:crypto';

// Only authenticated paired phones reach this API. Targets are this computer,
// never arbitrary hosts elsewhere on its LAN or cloud metadata addresses.
export class NetworkTunnels {
  constructor() { this.sessions = new Map(); }
  addresses() {
    return Object.entries(os.networkInterfaces()).filter(([name]) => /zerotier/i.test(name))
      .flatMap(([, rows]) => rows.filter(x => x.family === 'IPv4' && !x.internal).map(x => x.address));
  }
  async open(owner, host, port) {
    if (!['localhost','127.0.0.1','::1',...this.addresses()].includes(host)) throw Error('只允许访问已配对电脑本机的服务');
    if (!Number.isInteger(port) || port < 1 || port > 65535) throw Error('服务端口无效');
    if ([...this.sessions.values()].filter(x => x.owner === owner).length >= 8) throw Error('同时最多打开 8 个服务连接');
    const id = randomUUID(), socket = net.createConnection({host,port});
    const s = {owner,socket,buffer:Buffer.alloc(0),ended:false,error:null};this.sessions.set(id,s);
    socket.setTimeout(120000,()=>this.drop(id));
    socket.on('data',data=>{s.buffer=Buffer.concat([s.buffer,data]);if(s.buffer.length>=256*1024)socket.pause();});
    socket.on('end',()=>{s.ended=true;});
    socket.on('error',()=>{s.ended=true;s.error='目标服务连接失败';});
    socket.on('close',()=>{s.ended=true;});
    try { await new Promise((resolve,reject)=>{
      const timer=setTimeout(()=>reject(Error('目标服务连接超时')),10000);
      socket.once('connect',()=>{clearTimeout(timer);resolve();});socket.once('error',()=>{clearTimeout(timer);reject(Error('无法连接主机上的该服务'));});
    }); } catch(e) { this.drop(id);throw e; }
    return {id};
  }
  session(owner,id) { const s=this.sessions.get(id);if(!s||s.owner!==owner)throw Error('服务连接已关闭');return s; }
  read(owner,id) {
    const s=this.session(owner,id), data=s.buffer.subarray(0,128*1024);s.buffer=s.buffer.subarray(data.length);
    if(s.buffer.length<128*1024)s.socket.resume();
    const eof=s.ended&&!s.buffer.length;
    if(eof)this.drop(id);
    if(eof&&s.error&&!data.length)throw Error(s.error);
    return {data:data.toString('base64'),eof};
  }
  async write(owner,id,encoded) {
    const s=this.session(owner,id);
    if(typeof encoded!=='string'||encoded.length>90000||!/^[A-Za-z0-9+/]*={0,2}$/.test(encoded))throw Error('服务数据无效');
    const data=Buffer.from(encoded,'base64');if(data.length>65536)throw Error('服务数据过大');
    await new Promise((resolve,reject)=>s.socket.write(data,e=>e?reject(Error('服务写入失败')):resolve()));return {};
  }
  drop(id) {const s=this.sessions.get(id);if(s){this.sessions.delete(id);s.socket.destroy();}}
  closeOwner(owner) {for(const [id,s] of this.sessions)if(s.owner===owner)this.drop(id);}
  close() {for(const id of this.sessions.keys())this.drop(id);}
}

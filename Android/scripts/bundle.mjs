import {transform} from 'esbuild';
import fs from 'node:fs/promises';
import path from 'node:path';
const root=path.resolve(import.meta.dirname,'..');
const protocol=await fs.readFile(path.join(root,'../iFilePlus/Services/OpenClawProtocol.swift'),'utf8');
const launcher=protocol.match(/static let launcher = #"""\r?\n([\s\S]*?)\r?\n    """#/)[1].split(/\r?\n/).map(line=>line.replace(/^    /,'')).join('\n');
await fs.writeFile(path.join(root,'app/src/main/assets/openclaw-launcher.sh'),launcher+'\n');
for(const name of ['core','app']){
 let source=await fs.readFile(path.join(root,'web',name+'.js'),'utf8');
 if(name==='app')source+='\n'+await fs.readFile(path.join(root,'web/network.js'),'utf8');
 const {code}=await transform(source,{target:'chrome74',legalComments:'inline',charset:'utf8'});
 await fs.writeFile(path.join(root,'app/src/main/assets',name+'.js'),code);
}
// Vendor source is distributed under its adjacent license; lower syntax for Android 10 WebView.
for(const name of ['marked.js','purify.js']){const file=path.join(root,'app/src/main/assets/vendor',name);const {code}=await transform(await fs.readFile(file,'utf8'),{target:'chrome74',legalComments:'inline',minify:true});await fs.writeFile(file,code);}

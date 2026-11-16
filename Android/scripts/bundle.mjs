import {transform} from 'esbuild';
import fs from 'node:fs/promises';
import path from 'node:path';
const root=path.resolve(import.meta.dirname,'..');
for(const name of ['core','app']){
 const source=await fs.readFile(path.join(root,'web',name+'.js'),'utf8');
 const {code}=await transform(source,{target:'chrome74',legalComments:'inline',charset:'utf8'});
 await fs.writeFile(path.join(root,'app/src/main/assets',name+'.js'),code);
}
// Vendor source is distributed under its adjacent license; lower syntax for Android 10 WebView.
for(const name of ['marked.js','purify.js']){const file=path.join(root,'app/src/main/assets/vendor',name);const {code}=await transform(await fs.readFile(file,'utf8'),{target:'chrome74',legalComments:'inline',minify:true});await fs.writeFile(file,code);}

/* Android 10 stock WebView compatibility. */
if(!Array.prototype.at)Object.defineProperty(Array.prototype,'at',{value:function(i){i=Math.trunc(i)||0;return this[i<0?this.length+i:i];}});
if(!Array.prototype.findLast)Object.defineProperty(Array.prototype,'findLast',{value:function(fn){for(var i=this.length-1;i>=0;i--)if(fn(this[i],i,this))return this[i];}});
if(!String.prototype.replaceAll)Object.defineProperty(String.prototype,'replaceAll',{value:function(a,b){if(a instanceof RegExp)return this.replace(a,b);return this.split(a).join(b);}});
if(!crypto.randomUUID)crypto.randomUUID=function(){var bytes=new Uint8Array(16);crypto.getRandomValues(bytes);bytes[6]=(bytes[6]&15)|64;bytes[8]=(bytes[8]&63)|128;var h=Array.from(bytes,function(b){return b.toString(16).padStart(2,'0');}).join('');return h.slice(0,8)+'-'+h.slice(8,12)+'-'+h.slice(12,16)+'-'+h.slice(16,20)+'-'+h.slice(20);};

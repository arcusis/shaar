// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumBugReport.h"

// Recent diagnostics remain in the document, never in a browser-wide log or on a server.
static const char *const ARCBugReportScript = R"JS((function(post){
'use strict';
if(!/^https?:$/.test(location.protocol))return function(){};
const apply=Reflect.apply,stringify=JSON.stringify,clock=performance.now.bind(performance);
const consoleRows=[],network=[],resources=[],xhr=new WeakMap();
const trim=(v,n=2048)=>String(v).slice(0,n);
const append=(list,value,limit)=>{list.push(value);if(list.length>limit)list.shift();};
const describe=v=>{try{return trim(v instanceof Error?v.stack||v.message:typeof v==='string'?v:stringify(v)||String(v),4096);}catch{return '[unserializable]';}};
const headers=value=>{try{return [...new Headers(value)].slice(0,24).map(([name,value])=>({name:trim(name,128),value:trim(value,512)}));}catch{return [];}};
const log=(level,message)=>append(consoleRows,{level,message,time:performance.timeOrigin+clock()},300);
for(const level of ['log','info','warn','error','debug']){
  const original=console[level];if(typeof original!=='function')continue;
  console[level]=new Proxy(original,{apply(fn,receiver,args){try{log(level,args.map(describe).join(' ').slice(0,4096));}catch{}return apply(fn,receiver,args);}});
}
addEventListener('error',e=>log('error',trim(e.message+' '+(e.filename||'')+':'+e.lineno,4096)));
addEventListener('unhandledrejection',e=>log('unhandledrejection',describe(e.reason)));
const resource=e=>({url:trim(e.name),start:e.startTime,duration:e.duration,transfer:e.transferSize||0,encoded:e.encodedBodySize||0,decoded:e.decodedBodySize||0,status:e.responseStatus||0,initiator:e.initiatorType||e.entryType});
if(PerformanceObserver.supportedEntryTypes.includes('resource')){
  const observer=new PerformanceObserver(list=>{for(const e of list.getEntries())append(resources,resource(e),1000);});
  observer.observe({type:'resource',buffered:true});
}
if(typeof fetch==='function'){
  const original=fetch;
  globalThis.fetch=new Proxy(original,{apply(fn,receiver,args){
    let row;try{const [input,init]=args;row={url:trim(new URL(typeof input==='string'||input instanceof URL?input:input.url,document.baseURI).href),method:trim(init?.method||input?.method||'GET',32),headers:headers(init?.headers||input?.headers),start:clock()};}catch{}
    const pending=apply(fn,receiver,args);
    if(!row)return pending;
    return pending.then(response=>{try{row.status=response.status;row.responseHeaders=headers(response.headers);row.end=clock();append(network,row,200);}catch{}return response;},error=>{row.end=clock();row.error=describe(error);append(network,row,200);throw error;});
  }});
}
const proto=XMLHttpRequest.prototype,open=proto.open,send=proto.send,setHeader=proto.setRequestHeader;
proto.open=new Proxy(open,{apply(fn,receiver,args){const result=apply(fn,receiver,args);try{xhr.set(receiver,{method:trim(args[0],32),url:trim(new URL(args[1],document.baseURI).href),headers:[]});}catch{}return result;}});
proto.setRequestHeader=new Proxy(setHeader,{apply(fn,receiver,args){const result=apply(fn,receiver,args);const row=xhr.get(receiver);if(row&&row.headers.length<24)row.headers.push({name:trim(args[0],128),value:trim(args[1],512)});return result;}});
proto.send=new Proxy(send,{apply(fn,receiver,args){const row=xhr.get(receiver);if(row){row.start=clock();receiver.addEventListener('loadend',()=>{try{row.end=clock();row.status=receiver.status;row.responseHeaders=receiver.getAllResponseHeaders().trim().split(/[\r\n]+/).filter(Boolean).slice(0,24).map(line=>{const i=line.indexOf(':');return {name:trim(line.slice(0,i),128),value:trim(line.slice(i+1).trim(),512)};});append(network,row,200);}catch{}},{once:true});}return apply(fn,receiver,args);}});
Object.defineProperty(globalThis,'__shaarBugReportV1',{value:{snapshot(){
  const navigation=performance.getEntriesByType('navigation').map(resource);
  return {url:location.href,title:document.title,timeOrigin:performance.timeOrigin,viewport:{width:innerWidth,height:innerHeight,devicePixelRatio},console:consoleRows.slice(),network:network.slice(),resources:[...navigation,...resources].slice(-1001)};
}},configurable:false});
return function(){};
}))JS";

NSString *ARCBugReportPageScript(void) {
  return [NSString stringWithUTF8String:ARCBugReportScript];
}

// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

enum InspectorDiagnosticsScript {
  static let install = #"""
    (()=>{
      if(window!==top||!/^https?:$/.test(location.protocol))return false;
      const owner='__SHAAR_DIAGNOSTICS_OWNER__';
      if(globalThis.__shaarBugReportV1?.owner===owner&&!globalThis.__shaarBugReportV1.stopped)return true;
      globalThis.__shaarBugReportV1?.dispose();
      const apply=Reflect.apply,clock=performance.now.bind(performance),consoleRows=[],network=[],resources=[],xhr=new WeakMap(),restores=[],observers=[];
      let stopped=false;const startedAt=performance.timeOrigin+clock();
      const trim=(v,n=2048)=>String(v??'').slice(0,n),append=(list,value,limit)=>{if(stopped)return;list.push(value);if(list.length>limit)list.shift();};
      const describe=value=>{let remaining=80;const seen=new WeakSet();const copy=(v,depth=0)=>{if(--remaining<0)return '[Limit]';if(v===null)return null;if(typeof v==='string')return trim(v,1024);if(typeof v==='boolean')return v;if(typeof v==='number')return Number.isFinite(v)?v:String(v);if(typeof v==='undefined')return '[Undefined]';if(typeof v!=='object')return '['+typeof v+']';if(v instanceof Node)return '<'+v.nodeName.toLowerCase()+'>';if(depth>=2)return '[Object]';if(seen.has(v))return '[Circular]';seen.add(v);try{const out=Object.create(null),fields=Object.getOwnPropertyDescriptors(v);for(const key of Object.keys(fields).slice(0,16))out[trim(key,128)]='value' in fields[key]?copy(fields[key].value,depth+1):'[Accessor]';return out;}catch{return '[Unavailable]';}};try{return ['string','number','boolean','bigint','undefined'].includes(typeof value)?trim(String(value),4096):trim(JSON.stringify(copy(value)),4096);}catch{return '[Unavailable]';}};
      const headers=value=>{try{if(value instanceof Headers)return [...value.entries()].slice(0,24).map(([name,value])=>({name:trim(name,128),value:trim(value,512)}));if(value&&Object.getPrototypeOf(value)===Object.prototype)return Object.entries(Object.getOwnPropertyDescriptors(value)).filter(([,d])=>'value' in d&&['string','number','boolean'].includes(typeof d.value)).slice(0,24).map(([name,d])=>({name:trim(name,128),value:trim(d.value,512)}));}catch{}return [];};
      const own=(value,key)=>{try{return Object.getOwnPropertyDescriptor(value,key)?.value;}catch{return undefined;}};
      const wrap=(object,key,make)=>{const original=object[key];if(typeof original!=='function')return;const replacement=make(original);object[key]=replacement;restores.push(()=>{if(object[key]===replacement)object[key]=original;});};
      const log=(level,message)=>append(consoleRows,{level,message,time:performance.timeOrigin+clock()},300);
      for(const level of ['log','info','warn','error','debug'])wrap(console,level,original=>new Proxy(original,{apply(fn,receiver,args){try{log(level,args.map(describe).join(' ').slice(0,4096));}catch{}return apply(fn,receiver,args);}}));
      const onError=e=>log('error',trim(e.message+' '+(e.filename||'')+':'+e.lineno,4096)),onRejection=e=>log('unhandledrejection',describe(e.reason));
      addEventListener('error',onError);addEventListener('unhandledrejection',onRejection);
      const resource=e=>({url:trim(e.name),start:e.startTime,duration:e.duration,transfer:e.transferSize||0,encoded:e.encodedBodySize||0,decoded:e.decodedBodySize||0,status:e.responseStatus||0,initiator:e.initiatorType||e.entryType});
      if(PerformanceObserver.supportedEntryTypes.includes('resource')){const observer=new PerformanceObserver(list=>{for(const e of list.getEntries())append(resources,resource(e),1000);});observer.observe({type:'resource',buffered:true});observers.push(observer);}
      wrap(globalThis,'fetch',original=>new Proxy(original,{apply(fn,receiver,args){const start=clock(),pending=apply(fn,receiver,args);let row;try{const [input,init]=args;const request=input instanceof Request?input:null;const url=typeof input==='string'||input instanceof URL?input:request?.url;if(url)row={url:trim(new URL(url,document.baseURI).href),method:trim(own(init,'method')||request?.method||'GET',32),headers:headers(own(init,'headers')||request?.headers),start};}catch{}if(!row)return pending;
        return pending.then(response=>{try{row.status=response.status;row.responseHeaders=headers(response.headers);row.end=clock();append(network,row,200);}catch{}return response;},error=>{row.end=clock();row.error=describe(error);append(network,row,200);throw error;});}}));
      const proto=XMLHttpRequest.prototype;
      wrap(proto,'open',original=>new Proxy(original,{apply(fn,receiver,args){const result=apply(fn,receiver,args);try{if(typeof args[0]==='string'&&(typeof args[1]==='string'||args[1] instanceof URL))xhr.set(receiver,{method:trim(args[0],32),url:trim(new URL(args[1],document.baseURI).href),headers:[]});}catch{}return result;}}));
      wrap(proto,'setRequestHeader',original=>new Proxy(original,{apply(fn,receiver,args){const result=apply(fn,receiver,args),row=xhr.get(receiver);if(row&&row.headers.length<24)row.headers.push({name:trim(args[0],128),value:trim(args[1],512)});return result;}}));
      wrap(proto,'send',original=>new Proxy(original,{apply(fn,receiver,args){const row=xhr.get(receiver);if(row){row.start=clock();receiver.addEventListener('loadend',()=>{try{row.end=clock();row.status=receiver.status;row.responseHeaders=receiver.getAllResponseHeaders().trim().split(/[\r\n]+/).filter(Boolean).slice(0,24).map(line=>{const i=line.indexOf(':');return {name:trim(line.slice(0,i),128),value:trim(line.slice(i+1).trim(),512)};});append(network,row,200);}catch{}},{once:true});}return apply(fn,receiver,args);}}));
      const tech=()=>{const rows=[],names=new Set();const add=(name,version,source)=>{if(names.has(name)||rows.length>=20)return;names.add(name);rows.push({name,version:typeof version==='string'?trim(version,64):null,source});};
        if(globalThis.React?.version)add('React',React.version,'Runtime version');if(globalThis.Vue?.version)add('Vue',Vue.version,'Runtime version');
        if(globalThis.__NEXT_DATA__)add('Next.js',null,'Page bootstrap data');if(globalThis.__NUXT__)add('Nuxt',null,'Page bootstrap data');
        if(globalThis.__svelte?.v instanceof Set)add('Svelte',[...__svelte.v].join(', '),'Runtime major-version marker');
        if(globalThis.jQuery?.fn?.jquery)add('jQuery',jQuery.fn.jquery,'Runtime version');
        const angular=document.querySelector('[ng-version]');if(angular)add('Angular',angular.getAttribute('ng-version'),'DOM version marker');
        const generator=document.querySelector('meta[name="generator"]')?.content;if(generator)add(trim(generator,100),null,'Claimed generator metadata');
        let scanned=0;for(const node of document.querySelectorAll('*')){if(++scanned>1500)break;const keys=Object.keys(node);if(keys.some(key=>key.startsWith('__reactFiber$')||key.startsWith('__reactContainer$')))add('React',null,'DOM runtime marker');const vue=node.__vueParentComponent;if(vue)add('Vue',vue.appContext?.app?.version,'Component runtime marker');if(node.__svelte_meta)add('Svelte',null,'Development source marker');}
        return rows;
      };
      const area=kind=>{if(!['local','session'].includes(kind))throw Error('Unknown storage area.');return kind==='local'?localStorage:sessionStorage;};
      const storage=kind=>{try{const store=area(kind),items=[];let limited=store.length>200;for(let i=0;i<Math.min(store.length,200);i++){const key=store.key(i);if(key===null)continue;if(key.length>4096){limited=true;continue;}const value=store.getItem(key)||'';items.push({key:trim(key,4096),preview:trim(value,256),length:value.length});}return {items,truncated:limited};}catch{return {error:'Storage is not available in this document.'};}};
      const readStorage=(kind,key)=>{try{const value=area(kind).getItem(key);if(value!==null&&value.length>262144)return {error:'Value exceeds the 256K-character editor limit.'};return {value};}catch{return {error:'Storage could not be read.'};}};
      const writeStorage=(kind,key,value)=>{try{if(typeof key!=='string'||key.length>4096||value!==null&&(typeof value!=='string'||value.length>262144))return {error:'Storage key or value exceeds the editor limit.'};const store=area(kind);if(value===null)store.removeItem(key);else store.setItem(key,value);return {ok:true};}catch{return {error:'Storage could not be changed; it may be restricted or full.'};}};
      const api={owner,get stopped(){return stopped;},snapshot(){return {url:location.href,title:document.title,startedAt,timeOrigin:performance.timeOrigin,viewport:{width:innerWidth,height:innerHeight,devicePixelRatio,hidden:document.hidden},console:consoleRows.slice(),network:network.slice(),resources:[...performance.getEntriesByType('navigation').map(resource),...resources].slice(-1001)};},tech,storage,readStorage,writeStorage,
        dispose(){if(stopped)return;stopped=true;for(const observer of observers)observer.disconnect();for(const restore of restores.reverse())restore();removeEventListener('error',onError);removeEventListener('unhandledrejection',onRejection);consoleRows.length=network.length=resources.length=0;if(globalThis.__shaarBugReportV1===api)delete globalThis.__shaarBugReportV1;}};
      globalThis.__shaarBugReportV1=api;return true;
    })()
    """#
  static func dispose(owner: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [owner])
    let literal = String(data: data, encoding: .utf8)!
    return
      "(()=>{const api=globalThis.__shaarBugReportV1;if(api?.owner===\(literal)[0])api.dispose();return true;})()"
  }

}

// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

enum InspectorDetailsScript {
  static let install = #"""
    (()=>{
      const inspect=globalThis.__shaarInspectorV2;if(!inspect)return false;
      globalThis.__shaarInspectorDetails?.stop();
      const registered=[],windows=new Set(),documents=new WeakMap(),identities=new WeakMap();let nextID=0,entries=new Map(),lastElement=null;
      const id=value=>{if(!identities.has(value))identities.set(value,++nextID);return identities.get(value);};
      const cut=(value,n=256)=>String(value??'').slice(0,n);
      const register=e=>{const d=e.detail;if(d?.component&&registered.length<250&&!registered.some(row=>row.component===d.component))registered.push({component:d.component,name:cut(d.tagName,160),target:d.options?.target});};
      const scan=()=>{const live=new Set();const visit=(win,depth=0)=>{if(depth>8||live.size>=128)return;try{const doc=win.document;live.add(win);if(!windows.has(win)||documents.get(win)!==doc){windows.add(win);documents.set(win,doc);doc.addEventListener('SvelteRegisterComponent',register);win.addEventListener('load',scan,true);}for(let i=0;i<win.frames.length;i++)visit(win.frames[i],depth+1);}catch{}};visit(window);
        for(const win of windows){if(!live.has(win)){try{documents.get(win)?.removeEventListener('SvelteRegisterComponent',register);win.removeEventListener('load',scan,true);}catch{}windows.delete(win);}}};scan();
      const stop=()=>{for(const win of windows){try{documents.get(win)?.removeEventListener('SvelteRegisterComponent',register);win.removeEventListener('load',scan,true);}catch{}}windows.clear();registered.length=0;entries.clear();lastElement=null;};inspect.onStop(stop);
      const snapshot=value=>{let remaining=600,truncated=false;const seen=new WeakSet();
        const copy=(v,depth=0)=>{if(--remaining<0){truncated=true;return '[Limit]';}if(v===null)return null;
          if(typeof v==='string'){if(v.length>256)truncated=true;return cut(v);}
          if(typeof v==='number')return Number.isFinite(v)?v:String(v);
          if(typeof v==='boolean')return v;if(typeof v==='undefined')return '[Undefined]';
          if(typeof v==='bigint')return v.toString()+'n';if(typeof v==='symbol')return '[Symbol]';if(typeof v==='function')return '[Function]';
          if(v instanceof Node)return '<'+v.nodeName.toLowerCase()+'>';if(seen.has(v))return '[Circular]';if(depth>=3){truncated=true;return Array.isArray(v)?'[Array]':'[Object]';}seen.add(v);
          try{const descriptors=Object.getOwnPropertyDescriptors(v);if(descriptors.__v_isRef?.value===true&&descriptors._value)return copy(descriptors._value.value,depth+1);
            const keys=Object.keys(descriptors).filter(k=>descriptors[k].enumerable).slice(0,40);if(Object.keys(descriptors).length>40)truncated=true;
            const result=Array.isArray(v)?[]:Object.create(null);for(const key of keys){const descriptor=descriptors[key];const name=cut(key,128);result[name]='value' in descriptor?copy(descriptor.value,depth+1):'[Accessor]';}return result;
          }catch{return '[Unavailable]';}
        };return {value:copy(value),truncated};};
      const location=value=>{if(!value)return null;const file=value.fileName||value.file;if(!file)return null;const line=value.lineNumber??value.line,column=value.columnNumber??value.column;return cut(file,512)+(Number.isInteger(line)?':'+line:'')+(Number.isInteger(column)?':'+column:'');};
      const reactName=fiber=>{const t=fiber?.type;if(typeof t==='string'||!t)return null;if(typeof t==='function')return cut(t.displayName||t.name||'Anonymous component',160);return t.displayName||t.render?.displayName||t.render?.name?cut(t.displayName||t.render?.displayName||t.render?.name,160):null;};
      const owner=node=>{for(let el=node,steps=0;el&&steps++<64;el=el.parentElement){if(el.__svelte_meta)return {framework:'Svelte',value:el.__svelte_meta};const vue=el.__vueParentComponent||el.__vue__;if(vue)return {framework:'Vue',value:vue};const key=Object.keys(el).find(k=>k.startsWith('__reactFiber$')||k.startsWith('__reactInternalInstance$'));if(key)return {framework:'React',value:el[key]};}return null;};
      const rootOf=f=>{let count=0;while(f?.return&&count++<256)f=f.return;return f;};
      const components=()=>{const node=inspect.element();if(!node?.isConnected)return {framework:null,nodes:[],selected:null,limit:null};entries.clear();lastElement=node;let framework=null,selected=null,limited=false;
        const add=(object,name,parent,source,kind)=>{if(entries.size>=250&&!entries.has(id(object))){limited=true;return null;}if(kind==='react'&&object.alternate&&identities.has(object.alternate))identities.set(object,id(object.alternate));const identity=id(object);entries.set(identity,{id:identity,name:cut(name,160),parent,source,kind,object});return identity;};
        const ownership=owner(node);let fiber=ownership?.framework==='React'?ownership.value:null;
        if(fiber){framework='React';const oldRoot=rootOf(fiber),root=oldRoot?.stateNode?.current||oldRoot;if(root!==oldRoot&&fiber.alternate)fiber=fiber.alternate;
          let nearest=fiber,steps=0;while(nearest&&!reactName(nearest)&&steps++<256)nearest=nearest.return;
          const chain=[];for(let f=nearest,n=0;f&&n++<256;f=f.return)if(reactName(f))chain.unshift(f);
          let parent=null;for(const f of chain)parent=add(f,reactName(f),parent,location(f._debugSource),'react');selected=parent;
          const stack=[[root,null]];let visited=0;while(stack.length&&visited++<4000){const [f,owner]=stack.pop();if(!f)continue;let next=owner;const name=reactName(f);if(name)next=add(f,name,owner,location(f._debugSource),'react')??owner;if(f.sibling)stack.push([f.sibling,owner]);if(f.child)stack.push([f.child,next]);}
          if(stack.length)limited=true;
          if(selected&&entries.has(selected)&&!entries.get(selected).source)entries.get(selected).source=location(fiber?._debugSource);
        } else {
          const vue=ownership?.framework==='Vue'?ownership.value:null;
          if(vue){framework='Vue';if(vue.$options){const chain=[];for(let v=vue,n=0;v&&n++<64;v=v.$parent)chain.unshift(v);let parent=null;for(const v of chain)parent=add(v,v.$options?.name||'Anonymous component',parent,cut(v.$options?.__file||'',512)||null,'vue2');selected=id(vue);}
            else{let root=vue;for(let n=0;root.parent&&n++<64;)root=root.parent;const queue=[[root,null]],seen=new Set();let visits=0;
              while(queue.length&&visits++<4000){const [value,parent]=queue.pop();if(!value||seen.has(value))continue;seen.add(value);
                if(value.type&&value.subTree){const identity=add(value,value.type.name||value.type.__name||'Anonymous component',parent,cut(value.type.__file||'',512)||null,'vue3');queue.push([value.subTree,identity??parent]);}
                else{if(value.component)queue.push([value.component,parent]);if(Array.isArray(value.children))for(const child of value.children.slice(0,500))if(child&&typeof child==='object')queue.push([child,parent]);}
              }selected=id(vue);if(queue.length)limited=true;
            }
          } else {
            const metadata=node.__svelte_meta||node.closest('svg')?.__svelte_meta;let ancestor=node;
            while(!ancestor?.__svelte_meta&&ancestor?.parentElement)ancestor=ancestor.parentElement;
            const meta=metadata||ancestor?.__svelte_meta;
            if(meta){framework='Svelte';const chain=[];for(let entry=meta.parent,n=0;entry&&n++<64;entry=entry.parent)if(entry.type==='component'&&entry.file)chain.unshift(entry);
              let parent=null;for(const entry of chain)parent=add(entry,cut(entry.file.split('/').pop()?.replace(/\.svelte$/,''),160),parent,location(entry),'svelte-source');
              const file=meta.loc?.file||'',name=file.split('/').pop()?.replace(/\.svelte$/,'')||'Svelte component';
              const candidates=registered.filter(row=>row.name===name),owned=registered.filter(row=>row.name===name&&row.target?.contains?.(node));
              const row=owned.length===1?owned[0]:candidates.length===1?candidates[0]:null;
              selected=add(row?.component||meta,row?.name||name,parent,location(meta.loc?{...meta.loc,line:meta.loc.line+(Object.hasOwn(meta,'parent')?0:1),column:meta.loc.column+1}:null),row?'svelte4':'svelte-source');
            }
          }
        }
        return {framework,nodes:[...entries.values()].map(({object,kind,...row})=>row),selected,limit:limited?'Tree limited to 250 components and 4,000 runtime nodes':framework==='Svelte'?'Svelte exposes source ancestry; props/state require a captured development registration.':null};
      };
      const componentData=identity=>{if(inspect.element()!==lastElement)return null;const entry=entries.get(identity);if(!entry)return null;const value=entry.object;let props=null,state=null,hooks=null,note=null;
        try{if(entry.kind==='react'){props=value.memoizedProps;const classComponent=!!value.type?.prototype?.isReactComponent;if(classComponent)state=value.memoizedState;else{const slots=[];let hook=value.memoizedState;for(let n=0;hook&&n<64;n++,hook=hook.next){if(!Object.hasOwn(hook,'memoizedState'))break;slots.push({slot:n+1,value:hook.memoizedState});}hooks=slots;note='Raw hook state slots; custom hook structure and hook names are not inferred.';}}
          if(entry.kind==='vue3'){props=value.props;state={data:value.data,setup:value.devtoolsRawSetupState||value.setupState};}
          if(entry.kind==='vue2'){props=value.$props;state=value.$data;}
          if(entry.kind==='svelte4'){props=Object.fromEntries(Object.entries(value.$$.props||{}).map(([name,index])=>[name,value.$$.ctx?.[index]]));state=typeof value.$capture_state==='function'?value.$capture_state():null;note=state===null?'Development state capture is not exposed.':null;}
          if(entry.kind==='svelte-source')note='This build exposes source metadata only; component props and state are unavailable.';
        }catch{note='Runtime component data is no longer available.';}
        const p=snapshot(props),s=snapshot(state),h=snapshot(hooks);
        return {id:identity,name:entry.name,source:entry.source,props:JSON.stringify(p.value,null,2),state:JSON.stringify(s.value,null,2),hooks:JSON.stringify(h.value,null,2),truncated:p.truncated||s.truncated||h.truncated,note};
      };
      const accessibility=()=>{const node=inspect.element();if(!node)return null;const win=node.ownerDocument.defaultView;
        const visible=el=>{const style=win.getComputedStyle(el);return el.getClientRects().length>0&&!['hidden','collapse'].includes(style.visibility)&&!el.matches(':disabled')&&!el.closest('[inert]');};
        const candidates=[];let visited=0;for(const el of node.ownerDocument.querySelectorAll('a[href],area[href],button,input,select,textarea,[tabindex],[contenteditable]')){if(++visited>5000)break;if(!visible(el))continue;let index=el.tabIndex;if(index<0&&el.isContentEditable&&!el.parentElement?.isContentEditable)index=0;if(index>=0)candidates.push({el,index,order:candidates.length});}
        candidates.sort((a,b)=>(a.index>0&&b.index>0?a.index-b.index:a.index>0?-1:b.index>0?1:0)||a.order-b.order);
        const tab=candidates.findIndex(row=>row.el===node),aria=[...node.attributes].filter(a=>a.name.startsWith('aria-')).slice(0,64).map(a=>({name:cut(a.name,128),value:cut(a.value,512)})),warnings=[];
        if(node.localName==='img'&&!node.hasAttribute('alt'))warnings.push('Image has no alt attribute.');
        if(tab>=0&&node.closest('[aria-hidden="true" i]'))warnings.push('Focusable element is hidden from the accessibility tree.');
        if(node.id&&node.ownerDocument.querySelectorAll('#'+CSS.escape(node.id)).length>1)warnings.push('Element ID is duplicated.');
        return {aria,tabOrder:tab>=0?tab+1:null,tabLimit:visited>5000,warnings};
      };
      const assets=()=>{const node=inspect.element();if(!node)return null;const win=node.ownerDocument.defaultView,images=node.localName==='img'?[node]:[...node.querySelectorAll('img')].slice(0,16),svg=node.closest('svg')||node.querySelector('svg');
        return {images:images.map((img,index)=>{const url=img.currentSrc||img.src,r=img.getBoundingClientRect(),timing=win.performance.getEntriesByName(url).filter(e=>e.entryType==='resource').at(-1);return {index,url:cut(url,16384),renderedWidth:r.width,renderedHeight:r.height,naturalWidth:img.naturalWidth,naturalHeight:img.naturalHeight,transferSize:timing?.transferSize>0?timing.transferSize:null,bodySize:timing?.encodedBodySize>0?timing.encodedBodySize:null};}),svg:svg?(new TextEncoder().encode(svg.outerHTML).length<=262144?svg.outerHTML:svg.outerHTML.slice(0,1024)):null,svgTruncated:!!svg&&new TextEncoder().encode(svg.outerHTML).length>262144};
      };
      globalThis.__shaarInspectorDetails={componentName:node=>{const file=node?.__svelte_meta?.loc?.file;if(!file)return null;const name=String(file).split('/').pop().replace(/\.svelte$/,'');const rows=registered.filter(row=>row.name===name);return rows.length===1?rows[0].name:String(file).split('/').pop();},components,componentData,accessibility,assets,stop};return true;
    })()
    """#
}

// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

enum InspectorStyleScript {
  static let install = #"""
    (()=>{
      const inspect=globalThis.__shaarInspectorV2;if(!inspect)return false;
      globalThis.__shaarInspectorStyles?.stop();
      const history=[],listeners=new Set(),documents=new WeakMap();let lastMeasure=null,stopped=false;
      const svg=document.createElementNS('http://www.w3.org/2000/svg','svg');
      svg.style.cssText='position:fixed;inset:0;width:100%;height:100%;pointer-events:none;overflow:hidden;';inspect.addOverlay(svg);
      const live=node=>{try{return !!(node?.isConnected&&node.ownerDocument.defaultView?.document===node.ownerDocument);}catch{return false;}};
      const selected=id=>{const state=inspect.read();const node=inspect.element();return state.selection?.id===id&&state.selection.locked&&live(node)?node:null;};
      const rect=node=>{const r=node.getBoundingClientRect();let x=r.x,y=r.y,w=r.width,h=r.height;
        for(let win=node.ownerDocument.defaultView;win!==window;){const f=win.frameElement;if(!f)break;const b=f.getBoundingClientRect(),sx=b.width/(f.offsetWidth||b.width||1),sy=b.height/(f.offsetHeight||b.height||1);x=b.left+(x+f.clientLeft)*sx;y=b.top+(y+f.clientTop)*sy;w*=sx;h*=sy;win=f.ownerDocument.defaultView;}return {x,y,w,h};};
      const hit=(win,x,y,depth=0)=>{const el=win.document.elementFromPoint(x,y);if(el?.localName==='iframe'&&depth<8){try{const f=el.getBoundingClientRect(),child=el.contentWindow;void child.document;return hit(child,(x-f.x)/(f.width/(el.offsetWidth||f.width||1))-el.clientLeft,(y-f.y)/(f.height/(el.offsetHeight||f.height||1))-el.clientTop,depth+1)||el;}catch{}}return el;};
      const line=(x1,y1,x2,y2)=>{const el=document.createElementNS(svg.namespaceURI,'line');for(const [k,v] of Object.entries({x1,y1,x2,y2,stroke:'#ed4b82','stroke-width':1}))el.setAttribute(k,v);svg.append(el);
        const width=Math.max(0,Math.hypot(x2-x1,y2-y1)),text=document.createElementNS(svg.namespaceURI,'text');text.textContent=Math.round(width*100)/100+' px';text.setAttribute('x',(x1+x2)/2+4);text.setAttribute('y',(y1+y2)/2-4);text.setAttribute('fill','#ed4b82');text.setAttribute('stroke','Canvas');text.setAttribute('stroke-width','3');text.setAttribute('paint-order','stroke');text.style.font='11px ui-monospace,monospace';svg.append(text);return width;};
      const clear=()=>{svg.replaceChildren();lastMeasure=null;};
      const measure=e=>{if(!e.altKey){clear();return;}const state=inspect.read(),current=inspect.element();if(!state.selection?.locked||!live(current))return;
        const doc=e.view?.document||e.target?.ownerDocument||document;let x=e.clientX,y=e.clientY;
        for(let win=doc.defaultView;win&&win!==window;){const f=win.frameElement;if(!f)break;const b=f.getBoundingClientRect();x=b.x+(x+f.clientLeft)*b.width/(f.offsetWidth||b.width||1);y=b.y+(y+f.clientTop)*b.height/(f.offsetHeight||b.height||1);win=f.ownerDocument.defaultView;}
        const other=hit(window,x,y);if(!live(other)||other===current){clear();return;}
        const a=rect(current),b=rect(other);clear();const outline=document.createElementNS(svg.namespaceURI,'rect');for(const [k,v] of Object.entries({x:b.x,y:b.y,width:b.w,height:b.h,fill:'none',stroke:'#ed4b82','stroke-dasharray':'3 2'}))outline.setAttribute(k,v);svg.append(outline);
        const ax=a.x+a.w/2,ay=a.y+a.h/2,bx=b.x+b.w/2,by=b.y+b.h/2;
        const horizontal=a.x+a.w<=b.x?[a.x+a.w,b.x]:b.x+b.w<=a.x?[b.x+b.w,a.x]:[a.x,b.x];
        const vertical=a.y+a.h<=b.y?[a.y+a.h,b.y]:b.y+b.h<=a.y?[b.y+b.h,a.y]:[a.y,b.y];
        const dx=line(horizontal[0],Math.max(4,Math.min(ay,by)),horizontal[1],Math.max(4,Math.min(ay,by))),dy=line(Math.max(4,Math.min(ax,bx)),vertical[0],Math.max(4,Math.min(ax,bx)),vertical[1]);lastMeasure={horizontal:dx,vertical:dy};
      };
      const release=e=>{if(e.key==='Alt'||!e.altKey)clear();};
      const scan=()=>{const liveWindows=new Set();const visit=(win,depth=0)=>{if(depth>8||liveWindows.size>=128)return;try{const doc=win.document;liveWindows.add(win);if(!listeners.has(win)||documents.get(win)!==doc){listeners.add(win);documents.set(win,doc);win.addEventListener('pointermove',measure,true);win.addEventListener('keyup',release,true);win.addEventListener('blur',clear);win.addEventListener('load',scan,true);}for(let i=0;i<win.frames.length;i++)visit(win.frames[i],depth+1);}catch{}};visit(window);
        for(const win of listeners){if(!liveWindows.has(win)){try{win.removeEventListener('pointermove',measure,true);win.removeEventListener('keyup',release,true);win.removeEventListener('blur',clear);win.removeEventListener('load',scan,true);}catch{}listeners.delete(win);}}};scan();
      const stop=()=>{stopped=true;clear();svg.remove();history.length=0;for(const win of listeners){try{win.removeEventListener('pointermove',measure,true);win.removeEventListener('keyup',release,true);win.removeEventListener('blur',clear);win.removeEventListener('load',scan,true);}catch{}}listeners.clear();};inspect.onStop(stop);
      const edit=(id,property,value,priority)=>{const node=selected(id);if(stopped||!node)return {error:'Lock an element before editing.'};
        if(typeof property!=='string'||property.length>128||!/^--[\w-]+$|^-?[a-z][\w-]*$/i.test(property)||typeof value!=='string'||value.length>4096||value.includes('\0')||!['','important'].includes(priority))return {error:'Invalid CSS declaration.'};
        if(value&&!CSS.supports(property,value))return {error:'Chromium does not support this CSS value.'};
        const before=node.getAttribute('style');if(value)node.style.setProperty(property,value,priority);else node.style.removeProperty(property);
        const after=node.getAttribute('style');if(before!==after){history.push({node,before,after});if(history.length>50)history.shift();}return {ok:true,depth:history.length};};
      const undo=()=>{const change=history.at(-1);if(!change)return {error:'No edits to undo.'};if(!live(change.node)||change.node.getAttribute('style')!==change.after)return {error:'Page styles changed after this edit. Undo would overwrite them.'};
        if(change.before===null)change.node.removeAttribute('style');else change.node.setAttribute('style',change.before);history.pop();return {ok:true,depth:history.length};};
      const sourceFor=(selector,text)=>{const scratch=document.createElement('i').style;scratch.cssText=text;const normalized=scratch.cssText;if(!normalized)return null;
        const matches=new Set(),seen=new Set();let visited=0;
        const rules=(sheet,url,depth=0)=>{if(depth>16||seen.has(sheet)||visited>=12000)return;seen.add(sheet);let rows;try{rows=sheet.cssRules;}catch{return;}
          for(const rule of rows){if(++visited>12000)break;if(rule.selectorText===selector&&rule.style?.cssText===normalized)matches.add(url);
            if(rule.styleSheet)rules(rule.styleSheet,rule.styleSheet.href||url,depth+1);
            else if(rule.cssRules)rules(rule,url,depth+1);
          }};
        for(const win of listeners){try{const doc=win.document;for(let i=0;i<Math.min(128,doc.styleSheets.length);i++){const sheet=doc.styleSheets[i];rules(sheet,sheet.href||(sheet.ownerNode?.localName==='style'?doc.URL+'#style-'+(i+1):''));}}catch{}}
        return matches.size===1?[...matches][0]||null:null;};
      globalThis.__shaarInspectorStyles={sourceFor,stop,edit,undo,undoDepth:()=>history.length,measurement:()=>lastMeasure,
        clip:id=>{const node=selected(id);if(!node)return null;const r=rect(node);return {x:r.x+scrollX,y:r.y+scrollY,width:r.w,height:r.h,scale:2,devicePixelRatio};},
        sources:()=>{const out=[];let size=0;const seen=new Set();const visit=(doc,depth=0)=>{if(depth>8||seen.has(doc)||seen.size>=128)return;seen.add(doc);
          for(let i=0;i<Math.min(128,doc.styleSheets.length)&&out.length<128;i++){const sheet=doc.styleSheets[i],text=sheet.ownerNode?.localName==='style'?sheet.ownerNode.textContent:null;if(text&&text.length<=2097152&&size+text.length<=8388608){size+=text.length;out.push({text,url:doc.URL+'#style-'+(i+1)});}}
          for(const frame of doc.querySelectorAll('iframe')){try{if(frame.contentDocument)visit(frame.contentDocument,depth+1);}catch{}}};visit(document);return out;}};
      return true;
    })()
    """#
}

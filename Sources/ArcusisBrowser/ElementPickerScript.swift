// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

enum ElementPickerScript {
  static let install = #"""
    (()=>{
      globalThis.__shaarPickerV1?.stop();
      const docs=new Set();
      let selected=null,closed=false,last=null,queued=false,point=null;
      const shield=document.createElement('div');
      shield.dataset.shaarPicker='';
      shield.style.cssText='position:fixed;inset:0;z-index:2147483647;cursor:crosshair;pointer-events:auto;';
      const shadow=shield.attachShadow({mode:'closed'});
      const box=document.createElement('div'),label=document.createElement('div');
      box.style.cssText='position:fixed;display:none;border:2px solid #3478f6;background:rgba(52,120,246,.12);box-sizing:border-box;pointer-events:none;';
      label.style.cssText='position:fixed;display:none;padding:4px 7px;border-radius:5px;background:#245ac5;color:white;font:12px system-ui;pointer-events:none;';
      shadow.append(box,label);document.documentElement.append(shield);
      const normalize=s=>String(s||'').replace(/[\u200b\u00ad]/g,'').replace(/\s+/g,' ').trim();
      const quoted=s=>JSON.stringify(String(s));
      const escape=CSS.escape.bind(CSS);
      const unique=(doc,selector,node)=>{try{const all=doc.querySelectorAll(selector);return all.length===1&&all[0]===node;}catch{return false;}};
      const seeds=node=>{
        const result=[escape(node.localName)];
        if(node.id)result.push('#'+escape(node.id));
        for(const attr of ['data-testid','name','aria-label','title','role']){
          const value=node.getAttribute(attr);if(value)result.push('['+attr+'='+escape(value)+']');
        }
        const classes=[...node.classList].slice(0,8);
        for(const name of classes){result.push('.'+escape(name));result.push(escape(node.localName)+'.'+escape(name));}
        for(let a=0;a<classes.length;a++)for(let b=a+1;b<classes.length;b++)result.push('.'+escape(classes[a])+'.'+escape(classes[b]));
        return result;
      };
      const css=node=>{
        const doc=node.ownerDocument,candidates=seeds(node).filter(s=>unique(doc,s,node));
        let suffix='',current=node,depth=0;
        while(current&&current.nodeType===1&&depth++<256){
          const siblings=current.parentElement?[...current.parentElement.children].filter(n=>n.localName===current.localName):[current];
          const segment=escape(current.localName)+(siblings.length>1?':nth-of-type('+(siblings.indexOf(current)+1)+')':'');
          suffix=segment+(suffix?' > '+suffix:'');
          if(unique(doc,suffix,node))candidates.push(suffix);
          if(current!==node){for(const start of seeds(current)){
            for(const join of [' > ',' ']){const full=start+join+suffix.slice(segment.length+3);if(unique(doc,full,node))candidates.push(full);}
          }}
          current=current.parentElement;
        }
        return candidates.sort((a,b)=>a.length-b.length||a.localeCompare(b))[0]||null;
      };
      const literal=value=>{
        if(!value.includes("'"))return "'"+value+"'";
        if(!value.includes('"'))return '"'+value+'"';
        return 'concat('+value.split("'").map(part=>"'"+part+"'").join(',"\'",')+')';
      };
      const xpath=node=>{
        if(node.id&&node.ownerDocument.querySelectorAll('#'+escape(node.id)).length===1)return '//*[@id='+literal(node.id)+']';
        const parts=[];let current=node,depth=0;
        while(current&&current.nodeType===1&&depth++<256){
          const siblings=current.parentElement?[...current.parentElement.children].filter(n=>n.localName===current.localName):[current];
          parts.unshift('*[local-name()='+literal(current.localName)+']['+(siblings.indexOf(current)+1)+']');
          current=current.parentElement;
        }
        return current?null:'/'+parts.join('/');
      };
      const knownRoles=new Set(['button','link','heading','img','textbox','checkbox','radio','switch','combobox','listbox','slider','spinbutton','option','menuitem','tab','dialog','alert','status','listitem']);
      const role=node=>{
        if(node.getAttribute('role')){const explicit=node.getAttribute('role').split(/\s+/)[0];return knownRoles.has(explicit)?explicit:null;}
        const tag=node.localName;
        if(tag==='button')return 'button';if(tag==='a'&&node.hasAttribute('href'))return 'link';
        if(/^h[1-6]$/.test(tag))return 'heading';if(tag==='img')return 'img';if(tag==='textarea')return 'textbox';
        if(tag==='select')return node.multiple?'listbox':'combobox';
        if(tag==='input')return ({checkbox:'checkbox',radio:'radio',range:'slider',number:'spinbutton',search:'searchbox',button:'button',submit:'button',reset:'button',text:'textbox',email:'textbox',tel:'textbox',url:'textbox'})[node.type]||null;
        return null;
      };
      const name=node=>{
        const references=node.getAttribute('aria-labelledby');
        if(references)return normalize(references.split(/\s+/).map(id=>node.ownerDocument.getElementById(id)?.textContent||'').join(' '));
        if(node.hasAttribute('aria-label'))return normalize(node.getAttribute('aria-label'));
        if(node.labels?.length)return normalize([...node.labels].map(l=>l.textContent).join(' '));
        if(node.localName==='img')return normalize(node.getAttribute('alt'));
        if(node.localName==='input')return normalize(node.value);
        return normalize(node.innerText||node.textContent);
      };
      const confidentName=node=>{
        const references=node.getAttribute('aria-labelledby');
        if(references)return references.split(/\s+/).every(id=>{const el=node.ownerDocument.getElementById(id);return el&&el.childElementCount===0;});
        if(node.hasAttribute('aria-label'))return true;
        if(node.labels?.length)return [...node.labels].every(label=>[...label.children].every(child=>child===node));
        if(node.localName==='input')return ['button','submit','reset'].includes(node.type);
        if(node.childElementCount!==0||node.shadowRoot)return false;
        return [':before',':after'].every(pseudo=>['none','normal','""',"''"].includes(node.ownerDocument.defaultView.getComputedStyle(node,pseudo).content));
      };
      const exposed=node=>node.getClientRects().length>0&&node.ownerDocument.defaultView.getComputedStyle(node).visibility!=='hidden'&&!node.closest('[aria-hidden="true" i],[inert]');
      const locator=(node,selector,frames)=>{
        const doc=node.ownerDocument,all=[...doc.querySelectorAll('*')].filter(n=>n!==shield);let shadowed=false;
        for(let i=0;i<all.length;i++){const root=all[i].shadowRoot;if(root){shadowed=true;all.push(...root.querySelectorAll('*'));}}
        let prefix='page';for(const frame of frames)prefix+='.frameLocator('+quoted(frame)+')';
        const id=node.getAttribute('data-testid');
        if(id&&all.filter(el=>el.getAttribute('data-testid')===id).length===1)return {code:prefix+'.getByTestId('+quoted(id)+')',strategy:'testId',value:id};
        const r=role(node),n=name(node);
        const roleMatches=r?all.filter(el=>role(el)===r&&exposed(el)):[];
        if(r&&n&&exposed(node)&&roleMatches.every(confidentName)&&roleMatches.filter(el=>name(el)===n).length===1)
          return {code:prefix+'.getByRole('+quoted(r)+', { name: '+quoted(n)+', exact: true })',strategy:'role',value:r,name:n};
        const text=normalize(node.textContent);
        const textMatches=all.filter(el=>(normalize(el.textContent)===text&&![...el.children].some(child=>normalize(child.textContent)===text))||(el.localName==='input'&&['button','submit','reset'].includes(el.type)&&normalize(el.value)===text));
        if(node.childElementCount===0&&text&&text.length<=200&&textMatches.length===1&&textMatches[0]===node)
          return {code:prefix+'.getByText('+quoted(text)+', { exact: true })',strategy:'text',value:text};
        if(shadowed){const value='xpath='+xpath(node);return {code:prefix+'.locator('+quoted(value)+')',strategy:'xpath',value};}
        return {code:prefix+'.locator('+quoted(selector)+')',strategy:'css',value:selector};
      };
      const component=node=>{
        for(let el=node,depth=0;el&&depth++<64;el=el.parentElement){
          const key=Object.keys(el).find(k=>k.startsWith('__reactFiber$')||k.startsWith('__reactInternalInstance$'));
          if(key){for(let fiber=el[key],steps=0;fiber&&steps++<64;fiber=fiber.return){
            const type=fiber.type,componentName=typeof type==='function'?type.displayName||type.name:type?.displayName||type?.render?.displayName||type?.render?.name;
            if(componentName)return {framework:'React',name:String(componentName),source:fiber._debugSource?.fileName||null};
          }}
          const vue=el.__vueParentComponent;
          if(vue){const type=vue.type;return {framework:'Vue',name:type?.name||type?.__name||null,source:type?.__file||null};}
          if(el.__vue__){const options=el.__vue__.$options;return {framework:'Vue',name:options?.name||null,source:options?.__file||null};}
        }
        return null;
      };
      const hit=(win,x,y,frames=[])=>{
        const node=win.document.elementFromPoint(x,y);if(!node)return null;
        if(node.localName==='iframe'){
          try{const child=node.contentWindow;void child.document;
            const rect=node.getBoundingClientRect(),sx=rect.width/(node.offsetWidth||rect.width||1),sy=rect.height/(node.offsetHeight||rect.height||1);
            const selector=css(node);if(selector){const nested=hit(child,(x-rect.left)/sx-node.clientLeft,(y-rect.top)/sy-node.clientTop,[...frames,selector]);if(nested)return nested;}
          }catch{}
        }
        return {node,frames};
      };
      const atPoint=(x,y)=>{shield.style.pointerEvents='none';try{return hit(window,x,y);}finally{shield.style.pointerEvents=selected?'none':'auto';}};
      const paint=node=>{
        if(!node?.isConnected)return;
        let rect=node.getBoundingClientRect(),left=rect.left,top=rect.top,width=rect.width,height=rect.height;
        for(let win=node.ownerDocument.defaultView;win!==window;){const frame=win.frameElement;if(!frame)break;
          const r=frame.getBoundingClientRect(),sx=r.width/(frame.offsetWidth||r.width||1),sy=r.height/(frame.offsetHeight||r.height||1);
          left=r.left+(left+frame.clientLeft)*sx;top=r.top+(top+frame.clientTop)*sy;width*=sx;height*=sy;win=frame.ownerDocument.defaultView;
        }
        box.style.cssText+='display:block;left:'+left+'px;top:'+top+'px;width:'+width+'px;height:'+height+'px;';
        label.textContent='<'+node.localName+'> '+Math.round(rect.width)+' × '+Math.round(rect.height);
        label.style.cssText+='display:block;left:'+Math.max(0,Math.min(innerWidth-200,left))+'px;top:'+Math.max(0,top-28)+'px;';
      };
      const stop=()=>{closed=true;last=null;selected=null;point=null;shield.remove();for(const win of docs){try{win.removeEventListener('keydown',escapeKey,true);win.removeEventListener('load',scan,true);win.removeEventListener('scroll',scroll,true);}catch{}}docs.clear();};
      const escapeKey=e=>{if(e.key==='Escape'){e.preventDefault();e.stopImmediatePropagation();stop();}};
      const scroll=()=>{if(last)paint(last.node);};
      const scan=()=>{const visit=win=>{try{void win.document;if(!docs.has(win)){docs.add(win);win.addEventListener('keydown',escapeKey,true);win.addEventListener('load',scan,true);win.addEventListener('scroll',scroll,true);}for(let i=0;i<win.frames.length;i++)visit(win.frames[i]);}catch{}};visit(window);};
      shield.addEventListener('pointermove',e=>{point={x:e.clientX,y:e.clientY};if(queued)return;queued=true;requestAnimationFrame(()=>{queued=false;if(closed||selected)return;last=atPoint(point.x,point.y);if(last)paint(last.node);});});
      shield.addEventListener('click',e=>{e.preventDefault();e.stopImmediatePropagation();if(e.button!==0)return;last=atPoint(e.clientX,e.clientY);if(!last)return;
        const node=last.node,selector=css(node),path=xpath(node);if(!selector||!path)return;
        const rect=node.getBoundingClientRect();selected={css:selector,xpath:path,locator:locator(node,selector,last.frames),frames:last.frames,tag:node.localName,width:rect.width,height:rect.height,component:component(node)};
        shield.style.pointerEvents='none';paint(node);
      },true);
      shield.addEventListener('wheel',e=>{const found=atPoint(e.clientX,e.clientY);if(!found)return;e.preventDefault();
        for(let el=found.node;el;el=el.parentElement){const style=el.ownerDocument.defaultView.getComputedStyle(el);if(/auto|scroll/.test(style.overflowY+style.overflowX)&&(el.scrollHeight>el.clientHeight||el.scrollWidth>el.clientWidth)){el.scrollBy(e.deltaX,e.deltaY);return;}}
        found.node.ownerDocument.defaultView.scrollBy(e.deltaX,e.deltaY);
      },{passive:false});
      scan();globalThis.__shaarPickerV1={snapshot:()=>({closed,selection:selected,highlighted:shield.isConnected&&box.style.display==='block',hoverLabel:label.textContent}),stop};return true;
    })()
    """#
}

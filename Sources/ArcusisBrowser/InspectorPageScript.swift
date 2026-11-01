// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

enum InspectorPageScript {
  static let install = #"""
    (()=>{
      globalThis.__shaarInspectorV2?.stop();
      const docs=new Set(),nodes=new Map(),ids=new WeakMap(),documents=new WeakMap(),cleanups=[];
      let fontNodes=[],fontTruncated=false;
      let nextID=0,revision=0,current=null,locked=false,closed=false,frames=[],packet=null,quads=null,queued=false;
      const shield=document.createElement('div');
      shield.dataset.shaarInspector='';
      shield.style.cssText='all:initial;position:fixed;inset:0;z-index:2147483647;cursor:crosshair;pointer-events:auto;';
      const shadow=shield.attachShadow({mode:'closed'}),svg=document.createElementNS('http://www.w3.org/2000/svg','svg'),badge=document.createElement('div');
      svg.style.cssText='position:fixed;inset:0;width:100%;height:100%;pointer-events:none;overflow:hidden;';
      badge.style.cssText='all:initial;position:fixed;display:none;background:#202124;color:#fff;border-radius:4px;padding:5px 8px;font:11px ui-monospace,SFMono-Regular,monospace;line-height:16px;pointer-events:none;box-shadow:0 2px 6px #0003;';
      shadow.append(svg,badge);document.documentElement.append(shield);
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
          const svelte=globalThis.__shaarInspectorDetails?.componentName?.(el);if(svelte)return {framework:'Svelte',name:String(svelte).slice(0,160)};
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
      const identify=node=>{if(!ids.has(node))ids.set(node,++nextID);const id=ids.get(node);nodes.set(id,node);return id;};
      const attached=node=>{try{const win=node?.ownerDocument.defaultView;return !!(node?.isConnected&&win&&win.document===node.ownerDocument);}catch{return false;}};
      const parent=node=>node.parentElement||node.ownerDocument.defaultView?.frameElement;
      const context=node=>{const result=[];for(let win=node.ownerDocument.defaultView;win!==window;){const frame=win.frameElement;if(!frame)break;result.unshift(css(frame));win=frame.ownerDocument.defaultView;}return result;};
      const label=node=>node.localName+[...node.classList].slice(0,2).map(c=>'.'+c).join('');
      const topRect=node=>{
        const r=node.getBoundingClientRect();let x=r.left,y=r.top,w=r.width,h=r.height;
        for(let win=node.ownerDocument.defaultView;win!==window;){const f=win.frameElement;if(!f)break;
          const b=f.getBoundingClientRect(),sx=b.width/(f.offsetWidth||b.width||1),sy=b.height/(f.offsetHeight||b.height||1);
          x=b.left+(x+f.clientLeft)*sx;y=b.top+(y+f.clientTop)*sy;w*=sx;h*=sy;win=f.ownerDocument.defaultView;
        }return {x,y,w,h};
      };
      const rectQuad=(x,y,w,h)=>[x,y,x+w,y,x+w,y+h,x,y+h];
      const path=quad=>'M'+quad.reduce((s,n,i)=>s+(i?(i%2?' ': ' L'):'')+n,'')+' Z';
      const paint=()=>{
        if(!attached(current)){svg.replaceChildren();badge.style.display='none';return;}
        const r=topRect(current),s=current.ownerDocument.defaultView.getComputedStyle(current),num=v=>parseFloat(v)||0;
        const edges=prefix=>['Top','Right','Bottom','Left'].map(side=>num(s[prefix+side+(prefix==='border'?'Width':'')]));
        const b=edges('border'),p=edges('padding'),m=edges('margin'),scale=current.offsetWidth?r.w/current.offsetWidth:1;
        const inset=(outer,e)=>rectQuad(outer[0]+e[3]*scale,outer[1]+e[0]*scale,outer[2]-outer[0]-(e[1]+e[3])*scale,outer[5]-outer[1]-(e[0]+e[2])*scale);
        const border=rectQuad(r.x,r.y,r.w,r.h),padding=inset(border,b),content=inset(padding,p);
        const model=quads||{border,padding,content,margin:rectQuad(r.x-m[3]*scale,r.y-m[0]*scale,r.w+(m[1]+m[3])*scale,r.h+(m[0]+m[2])*scale)};
        svg.setAttribute('viewBox','0 0 '+innerWidth+' '+innerHeight);svg.replaceChildren();
        const layer=(outer,inner,color)=>{const el=document.createElementNS(svg.namespaceURI,'path');el.setAttribute('d',path(outer)+(inner?path(inner):''));el.setAttribute('fill',color);el.setAttribute('fill-rule','evenodd');svg.append(el);};
        layer(model.margin,model.border,'#f6b26b77');layer(model.border,model.padding,'#f8d87288');layer(model.padding,model.content,'#93c47d77');layer(model.content,null,'#6fa8dc55');
        const outline=document.createElementNS(svg.namespaceURI,'path');outline.setAttribute('d',path(model.border));outline.setAttribute('fill','none');outline.setAttribute('stroke','#3985ff');outline.setAttribute('stroke-width','1.5');svg.append(outline);
        const native=current.getBoundingClientRect();
        badge.textContent=label(current).slice(0,100)+'  '+Math.round(native.width*100)/100+' × '+Math.round(native.height*100)/100;
        badge.style.display='block';badge.style.left=Math.max(4,Math.min(innerWidth-badge.offsetWidth-4,r.x))+'px';
        badge.style.top=Math.max(4,r.y>=32?r.y-30:Math.min(innerHeight-28,r.y+r.h+4))+'px';
      };
      const canvas=document.createElement('canvas');canvas.width=canvas.height=1;const ctx=canvas.getContext('2d',{willReadFrequently:true});
      const color=value=>{const text=String(value),match=/^rgba?\(([^)]+)\)$/.exec(text);
        if(match){const parts=match[1].trim().split(/[,\s\/]+/),channel=(v,alpha=false)=>parseFloat(v)/(v.includes('%')?100:alpha?1:255);
          if(parts.length>=3)return {css:text.slice(0,256),rgba:parts.slice(0,3).map(v=>channel(v)).concat(parts[3]?channel(parts[3],true):1)};}
        ctx.clearRect(0,0,1,1);ctx.fillStyle=value;ctx.fillRect(0,0,1,1);const data=[...ctx.getImageData(0,0,1,1).data].map(n=>n/255);return {css:text.slice(0,256),rgba:data};};
      const over=(a,b)=>{const alpha=a[3]+b[3]*(1-a[3]);return alpha?a.slice(0,3).map((n,i)=>(n*a[3]+b[i]*b[3]*(1-a[3]))/alpha).concat(alpha):[0,0,0,0];};
      const collect=()=>{
        if(!attached(current))return null;
        const node=current,win=node.ownerDocument.defaultView,s=win.getComputedStyle(node),r=node.getBoundingClientRect();
        const edge=prefix=>['Top','Right','Bottom','Left'].map(side=>String(s[prefix+side+(prefix==='border'?'Width':'')]).slice(0,64));
        const number=v=>parseFloat(v)||0,p=edge('padding'),b=edge('border'),m=edge('margin');
        let backdrop=[0,0,0,0],limit=null,ancestor=node,steps=0;
        while(ancestor&&steps++<128){const style=ancestor.ownerDocument.defaultView.getComputedStyle(ancestor);
          if(style.backgroundImage!=='none')limit='Image or gradient behind text';
          if(Number(style.opacity)!==1||style.mixBlendMode!=='normal'||style.filter!=='none'||style.backdropFilter!=='none')limit='Opacity, filter, or blending requires pixel sampling';
          if(/color\(|okl|lab\(/.test(style.backgroundColor+style.color))limit='Wide-gamut colors shown as sRGB approximations';
          backdrop=over(backdrop,color(style.backgroundColor).rgba);ancestor=parent(ancestor);
        }
        const surface=document.createElement('i');surface.style.cssText='display:none;background:Canvas;color-scheme:'+s.colorScheme;
        shadow.append(surface);const canvasColor=getComputedStyle(surface).backgroundColor;surface.remove();
        backdrop=over(backdrop,color(canvasColor).rgba);
        const ancestry=[];for(let el=node;el&&ancestry.length<32;el=parent(el))ancestry.unshift({id:identify(el),label:label(el).slice(0,100)});
        const selector=css(node)||'',pathValue=xpath(node)||'',found=component(node);
        let jsPath='document';for(const frame of frames)jsPath+='.querySelector('+quoted(frame)+').contentDocument';
        jsPath+='.querySelector('+quoted(selector)+')';
        const colors=[{label:'Text',value:color(s.color)},{label:'Background',value:color(s.backgroundColor)}];
        const borderColors=['Top','Right','Bottom','Left'].map(side=>s['border'+side+'Color']);
        if(b.some(v=>number(v)>0)){
          if(new Set(borderColors).size===1)colors.push({label:'Border',value:color(borderColors[0])});
          else borderColors.forEach((value,i)=>colors.push({label:'Border '+['top','right','bottom','left'][i],value:color(value)}));
        }
        const contentSize=axis=>{const i=axis==='width'?1:0,extra=number(p[i])+number(p[i+2])+number(b[i])+number(b[i+2]),used=parseFloat(s[axis]);
          return Math.max(0,Number.isFinite(used)?used-(s.boxSizing==='border-box'?extra:0):r[axis]-extra);};
        return {id:identify(node),revision,locked,tag:node.localName,label:label(node).slice(0,512),component:found?.name||null,
          css:selector,xpath:pathValue,playwright:locator(node,selector,frames).code,jsPath,frames,ancestors:ancestry,
          box:{width:r.width,height:r.height,contentWidth:contentSize('width'),contentHeight:contentSize('height'),margin:m,border:b,padding:p},
          typography:{family:s.fontFamily.slice(0,512),size:s.fontSize,weight:s.fontWeight,lineHeight:s.lineHeight,letterSpacing:s.letterSpacing,preview:normalize(node.innerText||node.textContent).slice(0,200)},
          colors,foreground:color(s.color),backdrop:{css:'composited background',rgba:backdrop},contrastLimit:limit};
      };
      const choose=(node,lock=locked)=>{if(!attached(node)||node===shield)return;nodes.clear();current=node;locked=lock;frames=context(node);revision++;packet=null;quads=null;shield.style.pointerEvents=locked?'none':'auto';observer.disconnect();observer.observe(document.documentElement);observer.observe(node);paint();};
      const hit=(win,x,y,depth=0)=>{const node=win.document.elementFromPoint(x,y);if(!node)return null;
        if(node.localName==='iframe'&&depth<8){try{const frame=node.getBoundingClientRect(),child=node.contentWindow;void child.document;
          return hit(child,(x-frame.left)/(frame.width/(node.offsetWidth||frame.width||1))-node.clientLeft,(y-frame.top)/(frame.height/(node.offsetHeight||frame.height||1))-node.clientTop,depth+1)||node;}catch{}}
        return node;
      };
      const at=(x,y)=>{shield.style.pointerEvents='none';try{return hit(window,x,y);}finally{shield.style.pointerEvents=locked?'none':'auto';}};
      const stop=()=>{closed=true;for(const cleanup of cleanups){try{cleanup();}catch{}}cleanups.length=0;shield.remove();observer.disconnect();fontNodes=[];for(const win of docs){try{win.removeEventListener('keydown',key,true);win.removeEventListener('load',scan,true);win.removeEventListener('scroll',layout,true);win.removeEventListener('resize',layout);}catch{}}docs.clear();nodes.clear();current=null;};
      const visible=node=>node&&node.getClientRects().length>0;
      const navigate=direction=>{if(!attached(current))return;let next=null;
        if(direction==='up')next=parent(current);
        if(direction==='down')next=[...current.children].find(visible);
        if(direction==='left'||direction==='right'){next=direction==='left'?current.previousElementSibling:current.nextElementSibling;while(next&&!visible(next))next=direction==='left'?next.previousElementSibling:next.nextElementSibling;}
        if(next){choose(next,true);next.scrollIntoView({block:'nearest',inline:'nearest'});}
      };
      const key=e=>{if(e.key==='Escape'){e.preventDefault();e.stopImmediatePropagation();stop();}
        else if(current&&!e.metaKey&&!e.ctrlKey&&!e.altKey&&e.key.startsWith('Arrow')){e.preventDefault();e.stopImmediatePropagation();navigate(e.key.slice(5).toLowerCase());}};
      const layout=()=>{if(current){revision++;packet=null;quads=null;paint();}};
      const scan=()=>{const live=new Set();const visit=(win,depth=0)=>{if(depth>8||live.size>=128)return;try{const doc=win.document;live.add(win);
        if(!docs.has(win)||documents.get(win)!==doc){docs.add(win);documents.set(win,doc);win.addEventListener('keydown',key,true);win.addEventListener('load',scan,true);win.addEventListener('scroll',layout,true);win.addEventListener('resize',layout);}
        for(let i=0;i<win.frames.length;i++)visit(win.frames[i],depth+1);
      }catch{}};visit(window);for(const win of docs){if(!live.has(win)){try{win.removeEventListener('keydown',key,true);win.removeEventListener('load',scan,true);win.removeEventListener('scroll',layout,true);win.removeEventListener('resize',layout);}catch{}docs.delete(win);}}};
      const observer=new ResizeObserver(()=>{if(current)layout();});observer.observe(document.documentElement);
      shield.addEventListener('pointermove',e=>{if(locked||queued)return;queued=true;const x=e.clientX,y=e.clientY;requestAnimationFrame(()=>{queued=false;if(closed||locked)return;const node=at(x,y);if(node&&node!==current)choose(node,false);});});
      shield.addEventListener('click',e=>{e.preventDefault();e.stopImmediatePropagation();if(e.button===0)choose(at(e.clientX,e.clientY),true);},true);
      shield.addEventListener('wheel',e=>{const node=at(e.clientX,e.clientY);if(!node)return;e.preventDefault();for(let el=node;el;el=el.parentElement){const s=el.ownerDocument.defaultView.getComputedStyle(el);if(/auto|scroll/.test(s.overflowY+s.overflowX)&&(el.scrollHeight>el.clientHeight||el.scrollWidth>el.clientWidth)){el.scrollBy(e.deltaX,e.deltaY);return;}}node.ownerDocument.defaultView.scrollBy(e.deltaX,e.deltaY);},{passive:false});
      scan();
      const fontElements=()=>{const groups=new Map();fontTruncated=false;let documentIndex=0,visited=0;
        for(const win of docs){try{const body=win.document.body;if(!body)continue;
          const walker=win.document.createTreeWalker(body,NodeFilter.SHOW_TEXT);let text;
          while((text=walker.nextNode())){if(++visited>20000){fontTruncated=true;break;}const parent=text.parentElement;if(!parent||!text.textContent.trim()||!parent.getClientRects().length)continue;
            const style=win.getComputedStyle(parent);if(style.visibility==='hidden')continue;
            const script=/\p{Script=Han}/u.test(text.textContent)?'han':/\p{Script=Arabic}/u.test(text.textContent)?'arabic':/\p{Extended_Pictographic}/u.test(text.textContent)?'emoji':'text';
            const group=[documentIndex,style.fontFamily,style.fontWeight,style.fontStyle,style.fontStretch,style.fontFeatureSettings,style.fontVariationSettings,script].join('|');
            if(!groups.has(group)){if(groups.size>=160){fontTruncated=true;continue;}groups.set(group,parent);}
          }documentIndex++;
        }catch{}}
        fontNodes=[...groups.values()];return fontNodes;
      };
      let lastCollection=0;
      globalThis.__shaarInspectorV2={revision:()=>revision,read:()=>{if(current&&!attached(current)){current=null;locked=false;shield.style.pointerEvents='auto';packet=null;revision++;paint();}
        if(current&&(!packet||Date.now()-lastCollection>1000)){const next=collect();if(packet&&JSON.stringify(packet)!==JSON.stringify(next)){revision++;next.revision=revision;}packet=next;lastCollection=Date.now();}
        return {closed,revision,selection:packet};},
        element:()=>current,onStop:callback=>cleanups.push(callback),addOverlay:node=>shadow.append(node),visible:value=>{shield.style.visibility=value?'visible':'hidden';},fontElements,fontScanTruncated:()=>fontTruncated,overlay:()=>({painted:svg.childElementCount===5,badge:badge.textContent,colors:[...svg.children].slice(0,4).map(n=>n.getAttribute('fill'))}),choose:id=>{const node=nodes.get(id);if(attached(node))choose(node,true);return true;},
        pick:()=>{locked=false;packet=null;revision++;shield.style.pointerEvents='auto';paint();return true;},navigate,
        quads:(id,rev,model)=>{if(id===ids.get(current)&&rev===revision){quads=model;paint();}return true;},stop};
      return true;
    })()
    """#
}

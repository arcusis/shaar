// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

enum InspectorAICopyScript {
  static let install = #"""
    (()=>{
      const inspector=globalThis.__shaarInspectorV2;
      if(!inspector)throw Error('Inspector is not available.');
      if(globalThis.__shaarInspectorCopy?.inspector===inspector)return true;
      globalThis.__shaarInspectorCopy?.dispose();
      const omitted='input,textarea,select,option,optgroup,script,style,template,noscript,[contenteditable]';
      let capture=null;
      const normalize=s=>String(s||'').replace(/\s+/g,' ').trim();
      const clip=(raw,limit)=>{const value=normalize(raw);if(value.length<=limit)return value;const prefix=value.slice(0,limit),space=prefix.lastIndexOf(' ');return (space<0?'':prefix.slice(0,space))+'…';};
      const url=raw=>{try{const u=new URL(raw,location.href);u.search='';u.hash='';u.username='';u.password='';return u.href;}catch{return '';}};
      const secrets=()=>{
        const values=new Set(),visit=(win,depth=0)=>{if(depth>8)return;try{
          for(const el of win.document.querySelectorAll('input,textarea,select')){if(values.size>=2048)break;if(el.value)values.add(el.value);if(el.localName==='select')for(const option of el.selectedOptions)if(option.textContent)values.add(option.textContent);}
          for(let i=0;i<Math.min(win.frames.length,128);i++)visit(win.frames[i],depth+1);
        }catch{}};visit(window);const entries=[...values].sort((a,b)=>b.length-a.length);if(entries.reduce((n,v)=>n+v.length,0)>65536)throw Error('Form context exceeds the private copy limit.');return entries.length?new RegExp(entries.map(v=>{const escaped=v.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');return v.length<3?'(?<![A-Za-z0-9_])(?:'+escaped+')(?![A-Za-z0-9_])':escaped;}).join('|'),'g'):null;
      };
      const scrub=(value,values)=>values?String(value||'').replace(values,'[form value omitted]'):String(value||'');
      const safeText=(root,values,limit=1200,includeHidden=false)=>{
        if(!root||root.closest?.(omitted))return '';
        const walker=root.ownerDocument.createTreeWalker(root,NodeFilter.SHOW_TEXT);let node,result='',count=0;
        while((node=walker.nextNode())&&count++<4096&&result.length<2400){const el=node.parentElement;if(!el||el.closest(omitted))continue;if(!includeHidden){if(!el.getClientRects().length)continue;const style=el.ownerDocument.defaultView.getComputedStyle(el);if(style.visibility==='hidden'||style.display==='none')continue;}result+=' '+node.textContent;}
        return clip(scrub(result,values),limit);
      };
      const html=(root,values)=>{let visited=0;const walk=(node,depth)=>{
        if(++visited>128||depth>10)return {text:'…',attributes:[],children:[]};
        if(node.nodeType===3)return {text:scrub(normalize(node.textContent),values).slice(0,300),attributes:[],children:[]};
        if(node.nodeType!==1||node.matches(omitted)||node.matches('iframe,object,embed'))return null;
        const attributes=[...node.attributes].filter(a=>['id','class','role','aria-label','title','alt','href','src','data-testid'].includes(a.name)).slice(0,20).map(a=>({name:a.name,value:scrub(['href','src'].includes(a.name)?url(a.value):a.value,values).slice(0,512)}));
        return {tag:node.localName,attributes,children:[...node.childNodes].slice(0,64).map(child=>walk(child,depth+1)).filter(Boolean)};
      };return walk(root,0)||{text:'[Form control omitted]',attributes:[],children:[]};};
      const fullPath=node=>{const parts=[];for(let el=node;el&&parts.length<64;el=el.parentElement){const siblings=el.parentElement?[...el.parentElement.children].filter(n=>n.localName===el.localName):[el];parts.unshift(el.localName+':nth-of-type('+(siblings.indexOf(el)+1)+')');}return parts.join(' > ');};
      const context=id=>{
        const node=inspector.element(),selection=inspector.read().selection;
        if(!node?.isConnected||!selection?.locked||selection.id!==id)throw Error('Lock the same element again.');
        const values=secrets(),r=inspector.rectFor(node),style=node.ownerDocument.defaultView.getComputedStyle(node),metadata=inspector.copyMetadata();
        const refs=node.getAttribute('aria-labelledby');
        const accessibleName=node.closest(omitted)?'':refs?refs.split(/\s+/).map(key=>safeText(node.ownerDocument.getElementById(key),values,300,true)).join(' '):node.getAttribute('aria-label')||node.getAttribute('alt')||node.getAttribute('title')||(node.labels?.length?[...node.labels].map(label=>safeText(label,values,300,true)).join(' '):'');
        const ancestry=[];for(let el=node;el&&ancestry.length<64;el=el.parentElement)ancestry.unshift(el.localName);
        const own=safeText(node,values),seen=new Set();const neighbors=[node.previousElementSibling,node.nextElementSibling].filter(Boolean).map(el=>({tag:el.localName,text:safeText(el,values,300)})).filter(row=>row.text&&row.text!==own&&!seen.has(row.text)&&seen.add(row.text)).map(row=>row.tag+': '+row.text).join('\n');
        return {id,url:url(location.href),title:scrub(document.title,values).slice(0,300),tag:node.localName,
          accessibleName:clip(scrub(accessibleName,values),300),role:metadata?.role||'',selector:scrub(selection.css,values)===selection.css?selection.css:fullPath(node),
          source:scrub(metadata?.component?.source||'',values),components:metadata?.component?.name?[metadata.component.framework+': '+scrub(metadata.component.name,values)]:[],
          bounds:{x:r.x,y:r.y,width:r.w,height:r.h},classes:[...node.classList].slice(0,64),
          text:own,nearby:neighbors,styles:['display','position','font-size','color','background-color'].map(name=>({name,value:scrub(style.getPropertyValue(name),values).slice(0,512)})),
          html:html(node,values),ancestors:ancestry,domPath:[...selection.frames,fullPath(node)].join(' :: '),protected:!!node.closest(omitted)};
      };
      const sanitize=value=>{const values=secrets(),structural=new Set(['selector','domPath','tag','role','classes','ancestors','name']);let count=0;const walk=(v,depth=0,key='')=>{
        if(++count>100000||depth>24)return '[Limit]';if(typeof v==='string')return structural.has(key)?v:scrub(v,values);if(Array.isArray(v))return v.slice(0,1024).map(x=>walk(x,depth+1,key));if(v&&typeof v==='object')return Object.fromEntries(Object.entries(v).map(([k,v])=>[k,walk(v,depth+1,k)]));return v;
      };return walk(value);};
      const addedControl=node=>node.nodeType===1&&(node.matches('input,textarea,select,iframe,object,embed,[contenteditable]')||node.localName.includes('-')||node.querySelector('input,textarea,select,iframe,object,embed,[contenteditable]')||[...node.querySelectorAll('*')].some(el=>el.localName.includes('-')));
      const changed=records=>records.some(record=>[...record.addedNodes].some(addedControl));
      const end=token=>{if(!capture||token!==capture.token)return false;const current=capture;capture=null;const valid=current.valid&&!changed(current.observer.takeRecords())&&current.node.isConnected&&current.styles.every(([node])=>node.ownerDocument.defaultView.getComputedStyle(node).visibility==='hidden');current.observer.disconnect();current.layer.remove();for(const [node,original] of current.styles){if(node.style.getPropertyValue('visibility')==='hidden'&&node.style.getPropertyPriority('visibility')==='important'){if(original.value)node.style.setProperty('visibility',original.value,original.priority);else node.style.removeProperty('visibility');if(!original.hadAttribute&&!node.getAttribute('style'))node.removeAttribute('style');}}return valid;};
      const begin=id=>{
        const node=inspector.element();if(context(id).protected)throw Error('Form controls cannot be copied.');
        if(capture)end(capture.token);
        const targets=[...node.querySelectorAll('input,textarea,select,iframe,object,embed,[contenteditable]')];
        for(const el of node.querySelectorAll('*'))if(el.localName.includes('-')&&!targets.some(target=>target.contains(el)))targets.push(el);
        if(node.localName.includes('-'))targets.push(node);
        if(targets.length>1024)throw Error('Too many form controls for a private screenshot.');
        const layer=document.createElement('div');layer.dataset.shaarCopyMask='';layer.style.cssText='all:initial;position:absolute;left:0;top:0;width:0;height:0;pointer-events:none;z-index:2147483647';
        const shadow=layer.attachShadow({mode:'closed'}),styles=[];
        for(const target of targets){const rect=inspector.rectFor(target),mask=document.createElement('div');mask.style.cssText='all:initial;position:absolute;pointer-events:none;background:#808080;left:'+(rect.x+scrollX)+'px;top:'+(rect.y+scrollY)+'px;width:'+rect.w+'px;height:'+rect.h+'px;';shadow.append(mask);
          styles.push([target,{value:target.style.getPropertyValue('visibility'),priority:target.style.getPropertyPriority('visibility'),hadAttribute:target.hasAttribute('style')}]);target.style.setProperty('visibility','hidden','important');}
        document.documentElement.append(layer);const observer=new MutationObserver(records=>{if(capture&&changed(records))capture.valid=false;});observer.observe(node,{childList:true,subtree:true});capture={token:crypto.randomUUID(),layer,styles,node,observer,valid:true};if(targets.some(target=>target.ownerDocument.defaultView.getComputedStyle(target).visibility!=='hidden')){const token=capture.token;end(token);throw Error('The page prevented a private form capture.');}return capture.token;
      };
      const dispose=()=>{if(capture)end(capture.token);if(globalThis.__shaarInspectorCopy?.inspector===inspector)delete globalThis.__shaarInspectorCopy;};
      inspector.onStop(dispose);globalThis.__shaarInspectorCopy={inspector,context,sanitize,begin,end,dispose};return true;
    })()
    """#
}

// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Source hints are page-owned development metadata. A missing or ambiguous hint stays unavailable.
enum InspectorSourceScript {
  static let install = #"""
    (()=>{
      const inspect=globalThis.__shaarInspectorV2;
      if(!inspect)return false;
      if(globalThis.__shaarInspectorSource?.inspector===inspect)return true;
      const clean=value=>typeof value==='string'?value.slice(0,512):'';
      const attributes=node=>{
        for(let el=node,depth=0;el&&depth++<8;el=el.parentElement){
          const file=['data-source-file','data-inspector-file','data-locator-file','data-code-inspector-file'].map(key=>el.getAttribute(key)).find(Boolean);
          if(file){const line=Number(el.getAttribute('data-source-line')||el.getAttribute('data-inspector-line')||el.getAttribute('data-locator-line'));
            const column=Number(el.getAttribute('data-source-column')||el.getAttribute('data-inspector-column'));
            return {source:clean(file)+(Number.isInteger(line)&&line>0?':'+line:'')+(Number.isInteger(column)&&column>0?':'+column:''),kind:'attribute'};}
          const combined=['data-source','data-source-location','data-code-inspector','data-locatorjs'].map(key=>el.getAttribute(key)).find(Boolean);
          if(combined)return {source:clean(combined),kind:'attribute'};
        }return null;
      };
      const framework=node=>{
        const details=globalThis.__shaarInspectorDetails;
        if(details){const tree=details.components(),selected=tree.nodes.find(row=>row.id===tree.selected);
          if(selected){const chain=[];for(let row=selected,n=0;row&&n++<32;row=tree.nodes.find(item=>item.id===row.parent))chain.unshift(row.name);
            const data=details.componentData(selected.id);
            return {source:clean(data?.source||selected.source),component:clean(selected.name),chain:chain.map(clean),kind:tree.framework||'framework'};
          }}
        const ng=node.ownerDocument.defaultView.ng;
        if(ng?.getOwningComponent||ng?.getComponent){try{const component=ng.getOwningComponent?.(node)||ng.getComponent?.(node),type=component?.constructor;
          if(type){return {source:clean(type.__file||type.ɵcmp?.source||''),component:clean(type.name),chain:[clean(type.name)],kind:'Angular'};}}catch{}}
        return null;
      };
      const sameOrigin=url=>{try{const parsed=new URL(url,location.href);return parsed.origin===location.origin&&['http:','https:'].includes(parsed.protocol)?parsed:null;}catch{return null;}};
      const fetchText=async (url,deadline)=>{const target=sameOrigin(url);if(!target||performance.now()>=deadline)return null;
        const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),Math.min(1500,deadline-performance.now()));
        try{const response=await fetch(target.href,{signal:controller.signal,credentials:'same-origin'});
          if(!response.ok||Number(response.headers.get('content-length')||0)>1048576)return null;
          const reader=response.body?.getReader();if(!reader)return null;
          const decoder=new TextDecoder();let size=0,value='';
          while(true){const part=await reader.read();if(part.done)break;size+=part.value.byteLength;
            if(size>1048576){await reader.cancel();return null;}value+=decoder.decode(part.value,{stream:true});}
          return value+decoder.decode();
        }catch{return null;}finally{clearTimeout(timer);}
      };
      const mapped=async node=>{
        const id=node.id;if(!id||id.length>128||node.ownerDocument.querySelectorAll('#'+CSS.escape(id)).length!==1)return null;
        const deadline=performance.now()+2500;
        const expression=new RegExp('<'+node.localName+'\\b[^>]{0,400}\\bid\\s*=\\s*["\\\']'+id.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')+'["\\\']','g');
        const matches=[];
        for(const script of [...node.ownerDocument.scripts].filter(row=>row.src).slice(0,8)){
          if(performance.now()>=deadline)break;
          const body=await fetchText(script.src,deadline);if(!body)continue;
          const directive=body.match(/\/\/[#@]\s*sourceMappingURL=([^\s]+)/g)?.at(-1)?.split('=')[1];
          if(!directive||directive.startsWith('data:'))continue;
          let mapURL;try{mapURL=new URL(directive,script.src).href;}catch{continue;}
          const mapText=await fetchText(mapURL,deadline);if(!mapText)continue;
          let map;try{map=JSON.parse(mapText);}catch{continue;}
          if(!Array.isArray(map.sources)||!Array.isArray(map.sourcesContent))continue;
          for(let i=0;i<Math.min(map.sources.length,256);i++){
            const content=map.sourcesContent[i],source=map.sources[i];if(typeof content!=='string'||typeof source!=='string'||content.length>262144)continue;
            const hit=expression.exec(content);if(!hit){expression.lastIndex=0;continue;}
            if(expression.exec(content)){expression.lastIndex=0;return null;}expression.lastIndex=0;
            const line=content.slice(0,hit.index).split('\n').length;
            matches.push({source:clean(source)+':'+line,kind:'source map'});if(matches.length>1)return null;
          }
        }return matches[0]||null;
      };
      const resolve=async()=>{
        const node=inspect.element(),selection=inspect.read().selection;
        if(!node?.isConnected||!selection?.locked||selection.id!==inspect.read().selection?.id)return null;
        const identity=selection.id,attribute=attributes(node),component=framework(node);
        let source=attribute?.source||component?.source||'',kind=attribute?.kind||component?.kind||'';
        if(!source){const map=await mapped(node);source=map?.source||'';kind=map?.kind||kind;}
        if(inspect.read().selection?.id!==identity||inspect.element()!==node)return null;
        return {source,component:component?.component||'',chain:component?.chain||[],kind};
      };
      const stop=()=>{if(globalThis.__shaarInspectorSource?.resolve===resolve)delete globalThis.__shaarInspectorSource;};
      inspect.onStop(stop);globalThis.__shaarInspectorSource={inspector:inspect,resolve};return true;
    })()
    """#
}

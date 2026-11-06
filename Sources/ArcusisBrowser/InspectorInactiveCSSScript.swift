// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

enum InspectorInactiveCSSScript {
  private static let template = #"""
    ((properties)=>{
      const element=globalThis.__shaarInspectorV2?.element();
      if(!element)return {};
      const style=element.ownerDocument.defaultView.getComputedStyle(element);
      const parent=element.parentElement;
      const parentDisplay=parent?element.ownerDocument.defaultView.getComputedStyle(parent).display:'';
      const container=/^(inline-)?(flex|grid)$/.test(style.display);
      const parentContainer=/^(inline-)?(flex|grid)$/.test(parentDisplay);
      const flexContainer=style.display==='flex'||style.display==='inline-flex';
      const flexItem=parentDisplay==='flex'||parentDisplay==='inline-flex';
      const gridContainer=style.display==='grid'||style.display==='inline-grid';
      const gridItem=parentDisplay==='grid'||parentDisplay==='inline-grid';
      const replaced=new Set(['area','audio','canvas','embed','iframe','img','input','object','select','svg','textarea','video']);
      const reasons={};
      for(const raw of properties){
        const property=String(raw).toLowerCase();
        let reason=null;
        if(['justify-content','align-items','align-content','gap','row-gap','column-gap'].includes(property)&&!container&&style.columnCount==='auto')
          reason='Requires a flex or grid container.';
        else if(/^grid-(template|auto)/.test(property)&&!gridContainer)
          reason='Requires a grid container.';
        else if(/^grid-(column|row|area)/.test(property)&&!gridItem)
          reason='Requires a grid container or grid item.';
        else if(/^flex-(direction|wrap|flow)$/.test(property)&&!flexContainer)
          reason='Requires a flex container.';
        else if(/^(flex|flex-(basis|grow|shrink))$/.test(property)&&!flexItem)
          reason='Requires a flex container or flex item.';
        else if(['width','height','min-width','min-height','max-width','max-height'].includes(property)&&style.display==='inline'&&!replaced.has(element.localName))
          reason='Does not apply to non-replaced inline elements.';
        else if(property==='z-index'&&style.position==='static'&&!parentContainer)
          reason='Does not apply to static elements outside flex or grid layouts.';
        else if(property==='float'&&parentContainer)
          reason='Does not affect flex or grid items.';
        else if(property==='vertical-align'&&!/^(inline|inline-block|inline-flex|inline-grid|inline-table|table-cell)$/.test(style.display))
          reason='Does not apply to block-level boxes.';
        if(reason)reasons[property]=reason;
      }
      return reasons;
    })(__SHAAR_PROPERTIES__)
    """#

  static func expression(properties: [String]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: properties)) ?? Data("[]".utf8)
    let encoded = String(data: data, encoding: .utf8) ?? "[]"
    return template.replacingOccurrences(of: "__SHAAR_PROPERTIES__", with: encoded)
  }
}

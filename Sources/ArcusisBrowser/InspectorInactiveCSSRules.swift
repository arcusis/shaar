// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

enum InspectorInactiveCSSRules {
  private static let template = #"""
    ((properties)=>{
      const element=globalThis.__shaarInspectorV2?.element();
      if(!element)return {};
      const view=element.ownerDocument.defaultView;
      const style=view.getComputedStyle(element);
      const parent=element.parentElement;
      const parentDisplay=parent?view.getComputedStyle(parent).display:'';
      const flexContainer=['flex','inline-flex'].includes(style.display);
      const gridContainer=['grid','inline-grid'].includes(style.display);
      const flexItem=['flex','inline-flex'].includes(parentDisplay);
      const gridItem=['grid','inline-grid'].includes(parentDisplay);
      const replaced=new Set([
        'area','audio','canvas','embed','iframe','img','input','object','select','svg','textarea','video'
      ]);
      const inlineBox=/^(inline|inline-block|inline-flex|inline-grid|inline-table)$/.test(style.display);
      const textOverflowReady=style.display!=='inline'&&style.overflowX==='hidden'&&style.whiteSpace==='nowrap';
      const state={
        flexContainer,
        gridContainer,
        flexItem,
        gridItem,
        multiColumn:style.columnCount!=='auto'||style.columnWidth!=='auto',
        inlineElement:style.display==='inline'&&!replaced.has(element.localName),
        staticPosition:style.position==='static',
        inlineBox,
        tableCell:style.display==='table-cell',
        textOverflowReady
      };
      const rules=[
        {
          matches:property=>['justify-content','align-items'].includes(property),
          inactive:state=>!state.flexContainer&&!state.gridContainer,
          reason:'Requires a flex or grid container.'
        },
        {
          matches:property=>['gap','row-gap','column-gap','grid-gap','grid-row-gap','grid-column-gap'].includes(property),
          inactive:state=>!state.flexContainer&&!state.gridContainer&&!state.multiColumn,
          reason:'Requires a flex, grid, or multi-column container.'
        },
        {
          matches:property=>['flex-direction','flex-wrap','flex-flow'].includes(property),
          inactive:state=>!state.flexContainer,
          reason:'Requires a flex container.'
        },
        {
          matches:property=>['flex','flex-basis','flex-grow','flex-shrink'].includes(property),
          inactive:state=>!state.flexItem,
          reason:'Requires a flex item.'
        },
        {
          matches:property=>property==='grid'||/^grid-(template|auto)(-|$)/.test(property),
          inactive:state=>!state.gridContainer,
          reason:'Requires a grid container.'
        },
        {
          matches:property=>/^grid-(column|row|area)(-(start|end))?$/.test(property),
          inactive:state=>!state.gridItem,
          reason:'Requires a grid item.'
        },
        {
          matches:property=>property==='justify-items',
          inactive:state=>!state.gridContainer,
          reason:'Requires a grid container.'
        },
        {
          matches:property=>['width','height','margin-top','margin-bottom'].includes(property),
          inactive:state=>state.inlineElement,
          reason:'Does not affect non-replaced inline elements.'
        },
        {
          matches:property=>property==='z-index',
          inactive:state=>state.staticPosition&&!state.flexItem&&!state.gridItem,
          reason:'Requires positioning or a flex/grid item.'
        },
        {
          matches:property=>['top','right','bottom','left'].includes(property),
          inactive:state=>state.staticPosition,
          reason:'Does not apply to statically positioned elements.'
        },
        {
          matches:property=>property==='vertical-align',
          inactive:state=>!state.inlineBox&&!state.tableCell,
          reason:'Does not apply to block-level boxes.'
        },
        {
          matches:property=>property==='text-overflow',
          inactive:state=>!state.textOverflowReady,
          reason:'Requires overflow: hidden and white-space: nowrap.'
        },
        {
          matches:property=>property==='float',
          inactive:state=>state.flexItem||state.gridItem,
          reason:'Does not affect flex or grid items.'
        }
      ];
      const reasons={};
      for(const raw of properties){
        const property=String(raw).toLowerCase();
        const rule=rules.find(candidate=>candidate.matches(property)&&candidate.inactive(state));
        if(rule)reasons[property]=rule.reason;
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

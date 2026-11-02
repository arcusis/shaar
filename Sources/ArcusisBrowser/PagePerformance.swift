// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

enum PerformanceQuality: String {
  case unavailable, good, needsImprovement, poor

  static func rate(_ value: Double?, good: Double, poor: Double) -> Self {
    guard let value, value.isFinite, value >= 0 else { return .unavailable }
    if value <= good { return .good }
    return value <= poor ? .needsImprovement : .poor
  }

  var title: String {
    switch self {
    case .unavailable: "Unavailable"
    case .good: "Good"
    case .needsImprovement: "Needs improvement"
    case .poor: "Poor"
    }
  }
}

struct PagePerformanceSnapshot: Equatable {
  let timeOrigin: Double
  let lcp: Double?
  let inp: Double?
  let cls: Double?
  let fps: Double?
  let heapBytes: Double?
  let requests: Int
  let transferredBytes: Double

  var lcpQuality: PerformanceQuality { .rate(lcp, good: 2500, poor: 4000) }
  var inpQuality: PerformanceQuality { .rate(inp, good: 200, poor: 500) }
  var clsQuality: PerformanceQuality { .rate(cls, good: 0.1, poor: 0.25) }

  init(page: [String: Any], engineMetrics: [[String: Any]]) {
    func number(_ value: Any?) -> Double? {
      guard let value = value as? Double, value.isFinite, value >= 0 else { return nil }
      return value
    }
    timeOrigin = number(page["timeOrigin"]) ?? 0
    lcp = number(page["lcp"])
    inp = number(page["inp"])
    cls = number(page["cls"])
    fps = number(page["fps"])
    heapBytes = number(engineMetrics.first { $0["name"] as? String == "JSHeapUsedSize" }?["value"])
    requests = Int(min(number(page["requests"]) ?? 0, Double(Int32.max)))
    transferredBytes = number(page["bytes"]) ?? 0
  }
}

enum PagePerformanceScript {
  /// Core Web Vitals are navigation-local diagnostic values, not field percentile scores.
  static let install = #"""
    (()=>{
      if(globalThis.__shaarPerformanceV1)return true;
      const observers=[],interactions=new Map();
      let lcp=null,cls=0,session=0,firstShift=0,lastShift=0,fps=null,frames=0,lastFrame=performance.now(),raf=0;
      let requests=0,bytes=0,firstInteraction=Infinity,lastInteraction=0;
      const observe=(type,callback,extra={})=>{
        if(!PerformanceObserver.supportedEntryTypes.includes(type))return;
        const observer=new PerformanceObserver(list=>callback(list.getEntries()));
        observer.observe({type,buffered:true,...extra});observers.push(observer);
      };
      observe('largest-contentful-paint',entries=>{for(const e of entries)lcp=e.startTime;});
      observe('layout-shift',entries=>{for(const e of entries){
        if(e.hadRecentInput)continue;
        if(session && e.startTime-lastShift<1000 && e.startTime-firstShift<5000)session+=e.value;
        else{session=e.value;firstShift=e.startTime;}
        lastShift=e.startTime;cls=Math.max(cls,session);
      }});
      observe('event',entries=>{for(const e of entries){
        if(!e.interactionId)continue;
        firstInteraction=Math.min(firstInteraction,e.interactionId);
        lastInteraction=Math.max(lastInteraction,e.interactionId);
        interactions.set(e.interactionId,Math.max(interactions.get(e.interactionId)||0,e.duration));
        if(interactions.size>200){
          let key=null,min=Infinity;for(const [id,duration] of interactions)if(duration<min){min=duration;key=id;}
          interactions.delete(key);
        }
      }},{durationThreshold:16});
      observe('resource',entries=>{for(const e of entries){requests++;bytes+=e.transferSize||0;}});
      const navigation=performance.getEntriesByType('navigation')[0];
      if(navigation){requests++;bytes+=navigation.transferSize||0;}
      const tick=t=>{frames++;if(t-lastFrame>=1000){fps=frames*1000/(t-lastFrame);frames=0;lastFrame=t;}raf=requestAnimationFrame(tick);};
      raf=requestAnimationFrame(tick);
      globalThis.__shaarPerformanceV1={
        snapshot(){
          const sorted=[...interactions.values()].sort((a,b)=>b-a);
          const estimate=lastInteraction?(lastInteraction-firstInteraction)/7+1:0;
          const count=performance.interactionCount??estimate;
          const inp=sorted.length?sorted[Math.min(sorted.length-1,Math.floor(count/50))]:null;
          return {timeOrigin:performance.timeOrigin,lcp,inp,cls,fps:document.hidden?null:fps,requests,bytes};
        },
        dispose(){for(const o of observers)o.disconnect();cancelAnimationFrame(raf);delete globalThis.__shaarPerformanceV1;}
      };return true;
    })()
    """#
}

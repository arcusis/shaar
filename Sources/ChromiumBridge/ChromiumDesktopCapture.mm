// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumDesktopCapture.h"

NSString *const ARCDesktopCaptureRequestMessage = @"arcusisDesktopCaptureRequest";
NSString *const ARCDesktopCaptureResultMessage = @"arcusisDesktopCaptureResult";

NSString *ARCDesktopCapturePageScript(void) {
  return @"(function(post){"
    "const media=navigator.mediaDevices;"
    "if(!media||typeof media.getDisplayMedia!=='function'||typeof media.getUserMedia!=='function')return function(){};"
    "const getUserMedia=media.getUserMedia.bind(media),pending=new Map();"
    "const request=()=>new Promise(resolve=>{"
      "const id=crypto.randomUUID();pending.set(id,resolve);"
      "post('arcusisDesktopCaptureRequest',JSON.stringify({id,origin:location.origin}));"
    "});"
    "const getDisplayMedia=async function(options={}){"
      "if(options.video===false)throw new TypeError('getDisplayMedia requires video.');"
      "if(navigator.userActivation&&!navigator.userActivation.isActive)throw new DOMException('A user gesture is required.','InvalidStateError');"
      "const policy=document.permissionsPolicy||document.featurePolicy;"
      "if(policy&&typeof policy.allowsFeature==='function'&&!policy.allowsFeature('display-capture'))throw new DOMException('Display capture is not allowed.','NotAllowedError');"
      "const source=await request();"
      "if(!source)throw new DOMException('Screen sharing was cancelled.','NotAllowedError');"
      "const video={mandatory:{chromeMediaSource:'desktop',chromeMediaSourceId:source}};"
      "return getUserMedia({video,audio:false});"
    "};"
    "try{Object.defineProperty(media,'getDisplayMedia',{configurable:true,writable:true,value:getDisplayMedia});}catch(_){return function(){};}"
    "return function(kind,json){"
      "if(kind!=='arcusisDesktopCaptureResult')return;"
      "try{const result=JSON.parse(json),resolve=pending.get(result.id);if(!resolve)return;pending.delete(result.id);resolve(result.sourceId||null);}catch(_){}"
    "};})";
}

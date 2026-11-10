// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumDesktopCapture.h"

NSString *const ARCDesktopCaptureRequestMessage = @"arcusisDesktopCaptureRequest";
NSString *const ARCDesktopCaptureResultMessage = @"arcusisDesktopCaptureResult";

NSString *ARCDesktopCapturePageScript(void) {
  return ARCPagePromptScript();
}

NSString *ARCPagePromptScript(void) {
  static NSString *script;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    script = @(
        R"JS((() => {
  if (window.__shaarPrompts) return;
  const pending = new Map();
  const marker = "\u2060shaar-prompt\u2060";
  let previousTitle = document.title;
  window.__shaarPromptFinish = (id, source) => {
    const done = pending.get(id);
    if (!done) return false;
    pending.delete(id);
    document.title = previousTitle;
    done(source == null ? null : String(source));
    return true;
  };
  const ask = (kind) => new Promise((resolve) => {
    const id = crypto.randomUUID();
    pending.set(id, resolve);
    previousTitle = document.title;
    document.title = marker + kind + "\u2060" + id;
  });
  const media = navigator.mediaDevices;
  if (media && typeof media.getDisplayMedia === "function" && typeof media.getUserMedia === "function") {
    const getUserMedia = media.getUserMedia.bind(media);
    const getDisplayMedia = async function(options) {
      const settings = options || {};
      if (settings.video === false) throw new TypeError("getDisplayMedia requires video.");
      if (navigator.userActivation && !navigator.userActivation.isActive) {
        throw new DOMException("A user gesture is required.", "InvalidStateError");
      }
      const policy = document.permissionsPolicy || document.featurePolicy;
      if (policy && typeof policy.allowsFeature === "function" && !policy.allowsFeature("display-capture")) {
        throw new DOMException("Display capture is not allowed.", "NotAllowedError");
      }
      const source = await ask("display");
      if (!source) throw new DOMException("Screen sharing was cancelled.", "NotAllowedError");
      const video = {mandatory: {chromeMediaSource: "desktop", chromeMediaSourceId: source}};
      return getUserMedia({video: video, audio: false});
    };
    try {
      Object.defineProperty(media, "getDisplayMedia", {
        configurable: true, writable: true, value: getDisplayMedia});
    } catch (error) {}
  }
  window.__shaarPrompts = true;
})();)JS");
  });
  return script;
}

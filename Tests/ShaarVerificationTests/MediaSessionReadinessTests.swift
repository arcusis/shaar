// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import ChromiumBridgeVerification
import JavaScriptCore
import Testing

@testable import ArcusisBrowser
@testable import ShaarVerification

@Test func mediaReadinessWaitsForDecodedVideoAfterPlayingSignal() {
  var state = MediaSessionState(playbackState: .paused)
  #expect(!MediaSessionProbe.isPlaybackReady(state))
  state.playbackState = .playing
  #expect(!MediaSessionProbe.isPlaybackReady(state))
  state.hasVideo = true
  #expect(MediaSessionProbe.isPlaybackReady(state))
  state.playbackState = .paused
  #expect(!MediaSessionProbe.isPlaybackReady(state))
}

@Test @MainActor func mediaReporterPublishesDimensionsAfterPlaying() throws {
  let context = try #require(JSContext())
  context.evaluateScript(
    """
    const window=globalThis,scheduled=[],listeners={},reports=[];
    const location={protocol:'http:',href:'http://fixture.localhost/media'};
    const navigator={mediaSession:null};
    function setTimeout(callback){scheduled.push(callback);}
    function addEventListener(){}
    class HTMLMediaElement {
      constructor(){this.paused=false;this.ended=false;this.localName='video';
        this.videoWidth=0;this.duration=Infinity;this.seekable={length:0};
        this.volume=1;this.muted=false;}
      play(){}
    }
    class HTMLVideoElement extends HTMLMediaElement {}
    const video=new HTMLVideoElement();
    class Document {querySelectorAll(){return [video];}}
    const document=new Document();
    document.pictureInPictureElement=null;
    document.addEventListener=(type,callback)=>{listeners[type]=callback;};
    const flush=()=>{while(scheduled.length)scheduled.shift()();};
    const emit=type=>listeners[type]?.({type,target:video});
    """)
  let install = try #require(context.evaluateScript(ARCMediaSessionPageScript()))
  context.setObject(install, forKeyedSubscript: "install" as NSString)
  context.evaluateScript("install((kind,json)=>reports.push(JSON.parse(json)));")
  context.evaluateScript("emit('play');emit('playing');flush();")
  #expect(context.exception == nil)
  try #require(context.evaluateScript("reports.length")?.toInt32() == 1)
  #expect(context.evaluateScript("reports[0].playbackState")?.toString() == "playing")
  #expect(context.evaluateScript("reports[0].hasVideo")?.toBool() == false)

  // Deliver dimensions after the initial debounced report, as a delayed first frame can.
  context.evaluateScript("video.videoWidth=320;emit('resize');emit('resize');")
  try #require(context.evaluateScript("scheduled.length")?.toInt32() == 1)
  context.evaluateScript("flush();")
  try #require(context.evaluateScript("reports.length")?.toInt32() == 2)
  #expect(context.evaluateScript("reports[1].hasVideo")?.toBool() == true)
  #expect(context.evaluateScript("reports[1].playbackState")?.toString() == "playing")
  #expect(context.evaluateScript("reports[1].canSeek")?.toBool() == false)

  // A dimension event alone must not change playback or manufacture a decoded frame.
  context.evaluateScript("video.videoWidth=0;video.paused=true;emit('resize');flush();")
  #expect(context.evaluateScript("reports[2].hasVideo")?.toBool() == false)
  #expect(context.evaluateScript("reports[2].playbackState")?.toString() == "paused")
  context.evaluateScript("emit('resize');flush();")
  #expect(context.evaluateScript("reports.length")?.toInt32() == 3)
  #expect(context.exception == nil)
}

@Test func shaarNativeMediaStateKeepsVolumeAndLivePiPState() throws {
  let state = try #require(
    ARCProbeShaarMediaPublicState([
      "schemaVersion": 1, "playbackState": "playing", "title": "Song",
      "supportedActions": [0, 1, 4, 5], "hasVideo": true, "canSeek": true,
      "tabMuted": false, "silent": false, "pageVolume": 0.4,
      "pipVideoState": "inPictureInPicture", "pipVideoIsLive": true,
    ]))
  let payload = try #require(state as? [String: Any])
  let parsed = try #require(MediaSessionState(payload: payload))
  #expect(parsed.isPlaying && parsed.hasVideo && !parsed.silent)
  #expect(parsed.volume == 0.4)
  #expect(parsed.actions.contains(.seekBackward))
  #expect(parsed.actions.contains(.seekForward))
  #expect(parsed.pictureInPicture?.isLive == true)
}

@Test func shaarMediaEventsReachOnlyTheirOwnedTab() throws {
  let event: [String: Any] = [
    "schemaVersion": 1, "kind": "state_changed",
    "state": [
      "schemaVersion": 1, "playbackState": "playing", "title": "Fixture",
      "supportedActions": [0, 1], "hasVideo": true, "silent": false,
      "pipVideoState": "inPictureInPicture", "pipVideoIsLive": false,
    ],
  ]
  let owned = ARCProbeShaarMediaEventDispatch(event, true)
  let foreign = ARCProbeShaarMediaEventDispatch(event, false)
  #expect(owned["mediaCount"] as? Int == 1)
  #expect(owned["pipCount"] as? Int == 1)
  #expect(foreign["mediaCount"] as? Int == 0)
  #expect(foreign["pipCount"] as? Int == 0)
}

@Test func desktopCaptureRequestsReachTheObjectiveCReceivePathForOwnedTabs() throws {
  let id = UUID().uuidString
  let payload: [String: Any] = [
    "schemaVersion": 1,
    "promptID": id,
    "origin": "https://meet.google.com",
    "pageURL": "https://meet.google.com/example",
    "frameID": "0123456789abcdef0123456789abcdef",
    "sourceTypes": ["screen", "window", "tab"],
  ]
  let owned = ARCProbeDesktopCaptureEventDispatch(payload, true)
  let foreign = ARCProbeDesktopCaptureEventDispatch(payload, false)
  #expect(owned["id"] as? String == id)
  #expect(owned["kind"] as? String == "desktopCaptureRequested")
  #expect(owned["tabID"] as? String != nil)
  #expect(foreign.isEmpty)
}

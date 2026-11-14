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

@Test func shaarMediaStateRejectsNumericBooleanSubstitutes() throws {
  let payload = try #require(
    ARCProbeShaarMediaPublicState([
      "schemaVersion": 1, "playbackState": "playing", "supportedActions": [],
      "hasVideo": 1, "canSeek": 1, "tabMuted": 1, "silent": 1,
      "pipVideoState": "inPictureInPicture", "pipVideoIsLive": 1,
    ]) as? [String: Any])
  #expect(payload["hasVideo"] as? Bool == false)
  #expect(payload["canSeek"] as? Bool == false)
  #expect(payload["muted"] as? Bool == false)
  #expect(payload["silent"] as? Bool == false)
  let pip = try #require(payload["pictureInPicture"] as? [String: Any])
  #expect(pip["live"] as? Bool == false)
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

@Test func shaarMediaCaptureFlagsMustBeJSONBooleans() {
  let event: [String: Any] = [
    "schemaVersion": 1, "kind": "capture_changed",
    "camera": 1, "microphone": false, "screen": false,
  ]
  let result = ARCProbeShaarMediaEventDispatch(event, true)
  #expect(result["accessCount"] as? Int == 0)
}

@Test func privateShaarMediaCaptureFlagsMustBeJSONBooleans() {
  for key in ["camera", "microphone", "screen"] {
    var event: [String: Any] = [
      "schemaVersion": 1, "kind": "capture_changed",
      "camera": false, "microphone": false, "screen": false,
    ]
    event[key] = 1
    let result = ARCProbePrivateShaarMediaEventDispatch(event)
    #expect(result["accessCount"] as? Int == 0)
  }
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
  let ownedRequest = try #require(owned["request"] as? [String: Any])
  #expect(ownedRequest["id"] as? String == id)
  #expect(ownedRequest["kind"] as? String == "desktopCaptureRequested")
  #expect(ownedRequest["tabID"] as? String != nil)
  #expect(owned["resolutionCount"] as? Int == 0)
  #expect((foreign["request"] as? [String: Any])?.isEmpty == true)
  #expect(foreign["resolutionCount"] as? Int == 1)
  #expect(foreign["resolvedPromptID"] as? String == id)
  #expect(foreign["resolvedSourceID"] is NSNull)
}

@Test func webShareRequiresABIAndUserActivationOnTheObjectiveCReceivePath() throws {
  let id = UUID().uuidString
  let payload: [String: Any] = [
    "schemaVersion": 1,
    "id": id,
    "origin": "https://example.com",
    "pageURL": "https://example.com/article",
    "frameID": "0123456789abcdef0123456789abcdef",
    "userActivated": true,
    "title": "Share",
  ]
  let supported = ARCProbeWebShareEventDispatch(payload, 15, true, true)
  let received = try #require(supported["received"] as? [String: Any])
  #expect(received["id"] as? String == id)
  #expect(supported["replyOutcome"] as? Int == -1)

  let foreignWindow = ARCProbeWebShareEventDispatch(payload, 15, false, true)
  #expect((foreignWindow["received"] as? [String: Any])?.isEmpty == true)
  #expect(foreignWindow["replyID"] as? String == id)
  #expect(foreignWindow["replyOutcome"] as? Int == 0)

  var inactivePayload = payload
  inactivePayload["userActivated"] = false
  let inactive = ARCProbeWebShareEventDispatch(inactivePayload, 15, true, true)
  #expect((inactive["received"] as? [String: Any])?.isEmpty == true)
  #expect(inactive["replyID"] as? String == id)
  #expect(inactive["replyOutcome"] as? Int == 0)

  var numericActivationPayload = payload
  numericActivationPayload["userActivated"] = 1
  let numericActivation = ARCProbeWebShareEventDispatch(
    numericActivationPayload, 15, true, true)
  #expect((numericActivation["received"] as? [String: Any])?.isEmpty == true)
  #expect(numericActivation["replyID"] as? String == id)
  #expect(numericActivation["replyOutcome"] as? Int == 0)

  let oldABI = ARCProbeWebShareEventDispatch(payload, 14, true, true)
  #expect((oldABI["received"] as? [String: Any])?.isEmpty == true)
  #expect(oldABI["replyID"] as? String == "")
  #expect(oldABI["replyOutcome"] as? Int == -1)

  let missingReply = ARCProbeWebShareEventDispatch(payload, 15, true, false)
  #expect((missingReply["received"] as? [String: Any])?.isEmpty == true)
  #expect(missingReply["replyID"] as? String == "")
  #expect(missingReply["replyOutcome"] as? Int == -1)
}

@Test func closingAWindowCancelsOnlyItsPendingWebShareRequests() throws {
  let result = ARCProbeWebShareWindowCloseDispatch()

  #expect(result["replyID"] as? String == result["closedRequestID"] as? String)
  #expect(result["replyOutcome"] as? Int == 0)
  #expect(result["pendingRequestCount"] as? Int == 1)
}

@Test func printRequestsRequireABI16AndOwnedLiveTabOnTheObjectiveCReceivePath() throws {
  let id = UUID().uuidString
  let payload: [String: Any] = [
    "schemaVersion": 1,
    "id": id,
    "origin": "https://example.com",
    "pageURL": "https://example.com/article",
    "frameID": "0123456789abcdef0123456789abcdef",
    "title": "Print page",
  ]
  let supported = ARCProbePrintEventDispatch(payload, 16, true)
  let received = try #require(supported["received"] as? [String: Any])
  #expect(received["id"] as? String == id)
  #expect(received["kind"] as? String == "printRequested")
  #expect(supported["replyOutcome"] as? Int == -1)

  let foreign = ARCProbePrintEventDispatch(payload, 16, false)
  #expect((foreign["received"] as? [String: Any])?.isEmpty == true)
  #expect(foreign["replyID"] as? String == id)
  #expect(foreign["replyOutcome"] as? Int == 0)

  let oldABI = ARCProbePrintEventDispatch(payload, 15, true)
  #expect((oldABI["received"] as? [String: Any])?.isEmpty == true)
  #expect(oldABI["replyID"] as? String == "")
  #expect(oldABI["replyOutcome"] as? Int == -1)
}

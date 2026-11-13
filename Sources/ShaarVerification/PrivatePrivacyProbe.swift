// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import ChromiumBridgeVerification
import Foundation
import SwiftUI

@testable import ArcusisBrowser

enum PrivatePrivacyEvaluation {
  static func decode(_ json: String?) throws -> [String: Any] {
    guard let json, let data = json.data(using: .utf8),
      let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw PrivateWindowFailure("Private privacy script did not return an object.") }
    return result
  }
}

/// Paired normal/OTR behavior, using only the owned loopback listener.
@MainActor
struct PrivatePrivacyProbe {
  let runtime: ARCChromiumRuntime
  let root: URL
  let fixture: URL
  let phase: String
  let tabID: String
  let windowID: String
  let contextID: String
  let normalTabID: String

  func run() async throws -> Bool {
    var checks: [String: Bool] = [:]
    var observations: [String: Any] = [:]
    do {
      let prefs = runtime.privatePrivacyPreferences(forContextID: contextID) ?? [:]
      observations["preferences"] = prefs
      let engineStatus = await runtime.privatePrivacyStatus(forContextID: contextID)
      observations["engineStatus"] = engineStatus
      checks.merge(PrivatePrivacyEvidence.engineStatus(engineStatus)) { _, value in value }
      checks.merge(PrivatePrivacyEvidence.preferences(prefs)) { _, value in value }
      let normal = try await evaluate(normalTabID, storageScript)
      observations["normalStorage"] = normal
      checks["normalStoragePositiveControl"] =
        PrivatePrivacyEvidence.storage(normal, allowed: true, includesIndexedDB: false)
      let blocked = try await evaluate(tabID, storageScript)
      observations["blockedStorage"] = blocked
      checks["privateFirstPartyCookieAndStorageBlocked"] =
        PrivatePrivacyEvidence.storage(blocked, allowed: false, includesIndexedDB: true)
      let normalNetwork = try await evaluate(normalTabID, networkScript)
      let privateNetwork = try await evaluate(tabID, networkScript)
      observations["normalNetwork"] = normalNetwork
      observations["privateNetwork"] = privateNetwork
      checks["normalNetworkCookiePositiveControl"] =
        normalNetwork["cookieReturned"] as? Bool == true
      checks["privateFirstPartyNetworkReachable"] = privateNetwork["error"] == nil
      checks["privateNetworkCookiesBlocked"] = privateNetwork["cookieReturned"] as? Bool == false
      checks["privateTrackerRequestsBlocked"] =
        normalNetwork["tracker"] as? Bool == true && privateNetwork["tracker"] as? Bool == false
      checks["unlistedHTTPRequestsRemainAllowed"] =
        normalNetwork["otherHTTP"] as? Bool == true && privateNetwork["otherHTTP"] as? Bool == true
      let before = try await evaluate(tabID, "({visibility:document.visibilityState})")
      var presentation: [String: Any] = [
        "before": before["visibility"] ?? NSNull(),
        "nativeWindowsHiddenBefore": NSApp.windows.allSatisfy { !$0.isVisible },
      ]
      observations["permissionPresentation"] = presentation
      let permissions = try await evaluate(
        tabID,
        """
        (async()=>{let r={rendererVisibility:document.visibilityState};window.arcusisPrivatePermissionProbe=r;for(const name of ['camera','microphone','geolocation','notifications']){
          r.stage='query:'+name;
          try {r[name]=(await navigator.permissions.query({name})).state} catch(e) {r[name]=e.name}
        }
        for(const [key,constraints] of [['cameraRequest',{video:true}],['microphoneRequest',{audio:true}]]){
          r.stage=key;
          try{const stream=await navigator.mediaDevices.getUserMedia(constraints);stream.getTracks().forEach(t=>t.stop());r[key]='granted'}catch(e){r[key]=e.name}
        }
        r.stage='locationRequest';
        r.locationRequest=await new Promise(resolve=>navigator.geolocation.getCurrentPosition(()=>resolve(0),e=>resolve(e.code),{timeout:2000}));
        r.stage='notificationRequest';
        r.notificationRequest=await Notification.requestPermission();r.stage='complete';
        r.rendererVisibilityAtCompletion=document.visibilityState;return r})()
        """, permissionLease: true)
      observations["permissions"] = permissions
      checks.merge(PrivatePrivacyEvidence.permissions(permissions)) { _, value in value }
      let after = try await evaluate(tabID, "({visibility:document.visibilityState})")
      presentation["during"] = permissions["rendererVisibility"] ?? NSNull()
      presentation["completion"] = permissions["rendererVisibilityAtCompletion"] ?? NSNull()
      presentation["after"] = after["visibility"] ?? NSNull()
      presentation["nativeWindowsHiddenAfter"] = NSApp.windows.allSatisfy { !$0.isVisible }
      observations["permissionPresentation"] = presentation
      checks.merge(PrivatePrivacyEvidence.permissionPresentation(presentation)) { _, value in value
      }
      guard
        let model = PrivateSiteControlsModel(
          tabID: tabID, windowID: windowID, contextID: contextID,
          url: fixture, runtime: runtime)
      else {
        throw PrivateWindowFailure("Private site control model could not bind its web origin.")
      }
      await model.load()
      checks["privateSiteControlsReadBlockedDefault"] =
        model.allowed == false && model.failure == nil
      do {
        try await runtime.setPrivateCookiesAllowed(
          true, tabID: tabID, windowID: windowID, contextID: contextID,
          origin: "http://unrelated.localhost")
        checks["stalePrivateSiteControlOriginRejected"] = false
      } catch { checks["stalePrivateSiteControlOriginRejected"] = true }
      await model.setAllowed(true)
      checks["privateSiteControlsAllowAcknowledged"] = model.allowed == true && model.failure == nil
      try captureSiteControls(model)
      try await reload()
      let allowed = try await evaluate(tabID, storageScript)
      observations["allowedStorage"] = allowed
      checks["privatePerSiteAllowEnablesCookieAndStorage"] =
        PrivatePrivacyEvidence.storage(allowed, allowed: true, includesIndexedDB: true)
      let networkAllowed = try await evaluate(tabID, networkScript)
      checks["privatePerSiteAllowEnablesNetworkCookies"] =
        networkAllowed["cookieReturned"] as? Bool == true
      await model.setAllowed(false)
      checks["privateSiteControlsRevokeAcknowledged"] =
        model.allowed == false && model.failure == nil
      try await reload()
      let revoked = try await evaluate(tabID, storageScript)
      observations["revokedStorage"] = revoked
      checks["privatePerSiteRevokeBlocksStorageAgain"] =
        PrivatePrivacyEvidence.storage(revoked, allowed: false, includesIndexedDB: false)
      let passed = !checks.isEmpty && checks.values.allSatisfy { $0 }
      try report(checks, observations, error: nil)
      guard passed else {
        throw PrivateWindowFailure(
          "Private privacy checks failed: \(checks.filter { !$0.value }.keys.sorted().joined(separator: ", "))."
        )
      }
      return true
    } catch {
      if let diagnostic = try? await evaluate(
        tabID,
        "({permissionProgress:window.arcusisPrivatePermissionProbe ?? null,visibility:document.visibilityState})"
      ) {
        observations["permissionFailureDiagnostic"] = diagnostic
      }
      observations["nativeWindowsHiddenAfterFailure"] = NSApp.windows.allSatisfy { !$0.isVisible }
      try? report(checks, observations, error: error.localizedDescription)
      throw error
    }
  }

  private func captureSiteControls(_ model: PrivateSiteControlsModel) throws {
    guard let window = runtime.window(forPrivateWindowID: windowID, contextID: contextID),
      !window.isVisible,
      let container = runtime.hostView(forPrivateWindowID: windowID, contextID: contextID)
    else { throw PrivateWindowFailure("Private site controls need an owned hidden window.") }
    let view = NSHostingView(
      rootView: PrivateSiteControlsPanel(model: model)
        .frame(width: 340, height: 330, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor)))
    view.frame = NSRect(x: 0, y: 0, width: 340, height: 330)
    container.addSubview(view)
    defer { view.removeFromSuperview() }
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      view.appearance = NSAppearance(named: appearance)
      view.layoutSubtreeIfNeeded()
      guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        throw PrivateWindowFailure("Private site controls bitmap unavailable.")
      }
      view.cacheDisplay(in: view.bounds, to: bitmap)
      guard let png = bitmap.representation(using: .png, properties: [:]), png.count > 4096 else {
        throw PrivateWindowFailure("Private site controls capture was empty.")
      }
      try png.write(to: root.appending(path: "\(phase)-private-site-controls-\(name).png"))
    }
  }

  private var storageScript: String {
    """
    (async()=>{const r={};try{document.cookie='privacyJS=1; Path=/; SameSite=Lax';r.cookie=document.cookie.includes('privacyJS=1')}catch{r.cookie=false}
    for(const [key,store] of [['local','localStorage'],['session','sessionStorage']]){
      try{window[store].setItem('privacyProbe','1');r[key]=window[store].getItem('privacyProbe')==='1';window[store].removeItem('privacyProbe')}catch{r[key]=false}
    }
    r.indexedDB=await new Promise(resolve=>{try{const q=indexedDB.open('privacyProbe');q.onerror=()=>resolve(false);q.onsuccess=()=>{q.result.close();resolve(true)}}catch{resolve(false)}});
    try{document.cookie='privacyJS=; Max-Age=0; Path=/'}catch{}
    return r})()
    """
  }

  private func reload() async throws {
    let before =
      try await evaluate(tabID, "({instance:window.arcusisInstance})")["instance"] as? String
    guard runtime.reloadPrivateTabID(tabID, windowID: windowID, contextID: contextID) else {
      throw PrivateWindowFailure("Private privacy fixture could not reload.")
    }
    for _ in 0..<100 {
      try await Task.sleep(for: .milliseconds(50))
      if let value = try? await evaluate(tabID, "({instance:window.arcusisInstance})")["instance"]
        as? String,
        value != before
      {
        return
      }
    }
    throw PrivateWindowFailure("Private privacy fixture reload timed out.")
  }

  private var networkScript: String {
    let port = fixture.port!
    return """
      (async()=>{const r={};try {await fetch('/private-privacy/cookie',{credentials:'include'});
      const v=await (await fetch('/private-privacy/cookie',{credentials:'include'})).json();r.cookieReturned=v.cookie.includes('privacyHttp=1');
      for(const [key,host] of [['tracker','trackertest.org'],['otherHTTP','localhost']]){
        try{const q=await fetch('http://'+host+':\(port)/private-privacy/resource');r[key]=q.ok&&(await q.json()).fixture==='privacy'}catch{r[key]=false}
      }} catch(e) {r.error=String(e)} return r})()
      """
  }

  private func evaluate(_ tab: String, _ script: String, permissionLease: Bool = false)
    async throws -> [String: Any]
  {
    let json: String? = await withCheckedContinuation { continuation in
      if permissionLease {
        runtime.evaluatePrivatePermissionProbeTabID(tab, script: script) {
          continuation.resume(returning: $0)
        }
      } else {
        runtime.evaluatePrivacyProbeTabID(tab, script: script) {
          continuation.resume(returning: $0)
        }
      }
    }
    return try PrivatePrivacyEvaluation.decode(json)
  }

  private func report(_ checks: [String: Bool], _ observations: [String: Any], error: String?)
    throws
  {
    let report: [String: Any] = [
      "schema": 1, "phase": phase,
      "passed": error == nil && !checks.isEmpty && checks.values.allSatisfy { $0 },
      "capabilities": [
        "hostOpenedOriginCookieAndStorageBlock": "enforced",
        "perSiteCookieAndStorageAllow": "enforced-after-reload",
        "privateAutofillAndPasswordSaving": "disabled",
        "globalCookieAndStorageBlock": "engine-enforced",
        "trackerRequestBlocking": "engine-enforced",
        "engineWideHTTPSOnly": "engine-enforced",
        "privateReferrerAndWebRTCPolicy": "engine-enforced",
        "disablePreviouslyPermittedPrivateExtensions": "engine-enforced",
      ],
      "checks": checks, "observations": observations, "error": error as Any? ?? NSNull(),
      "limits": [],
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: root.appending(path: "\(phase)-private-privacy.json"), options: .atomic)
  }
}

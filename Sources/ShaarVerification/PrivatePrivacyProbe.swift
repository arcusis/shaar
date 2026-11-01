// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge.Verification
import Foundation
import SwiftUI

@testable import ArcusisBrowser

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
      let acknowledged: Bool = await withCheckedContinuation { continuation in
        runtime.probePrivateNetworkControls(forTabID: tabID) { continuation.resume(returning: $0) }
      }
      checks["cdpNetworkCommandsAcknowledged"] = acknowledged
      try await Task.sleep(for: .milliseconds(100))
      let privateNetwork = try await evaluate(tabID, networkScript)
      observations["normalNetwork"] = normalNetwork
      observations["privateNetwork"] = privateNetwork
      checks["normalNetworkCookiePositiveControl"] =
        normalNetwork["cookieReturned"] as? Bool == true
      checks["privateNetworkCookiesBlocked"] = privateNetwork["cookieReturned"] as? Bool == false
      checks["trackerBlockingUnavailableAfterCDPDetach"] =
        normalNetwork["tracker"] as? Bool == true && privateNetwork["tracker"] as? Bool == true
      checks["thirdPartyHTTPRequestsRemainAllowedAfterCDPDetach"] =
        normalNetwork["otherHTTP"] as? Bool == true && privateNetwork["otherHTTP"] as? Bool == true
      checks["httpsOnlyUnavailableAfterCDPDetach"] = try await checkHTTPBlock()
      let permissions = try await evaluate(
        tabID,
        """
        (async()=>{let r={};for(const name of ['camera','microphone','geolocation','notifications']){
          try {r[name]=(await navigator.permissions.query({name})).state} catch(e) {r[name]=e.name}
        }
        for(const [key,constraints] of [['cameraRequest',{video:true}],['microphoneRequest',{audio:true}]]){
          try{const stream=await navigator.mediaDevices.getUserMedia(constraints);stream.getTracks().forEach(t=>t.stop());r[key]='granted'}catch(e){r[key]=e.name}
        }
        r.locationRequest=await new Promise(resolve=>navigator.geolocation.getCurrentPosition(()=>resolve(0),e=>resolve(e.code),{timeout:2000}));
        r.notificationRequest=await Notification.requestPermission();return r})()
        """)
      observations["permissions"] = permissions
      checks.merge(PrivatePrivacyEvidence.permissions(permissions)) { _, value in value }
      let store = PrivateBrowserStore(
        contextID: contextID, windowID: windowID, tabID: tabID,
        url: fixture.absoluteString)
      guard let model = PrivateSiteControlsModel(store: store, runtime: runtime) else {
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

  private func checkHTTPBlock() async throws -> Bool {
    let id = UUID().uuidString.uppercased()
    try runtime.openPrivateTabID(id, windowID: windowID, contextID: contextID, url: "about:blank")
    for _ in 0..<100 {
      if runtime.privatePrivacyStatus(forProbeTabID: id)?["ready"] as? Bool == true { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    let acknowledged: Bool = await withCheckedContinuation { continuation in
      runtime.probePrivateNetworkControls(forTabID: id) { continuation.resume(returning: $0) }
    }
    try await Task.sleep(for: .milliseconds(100))
    let address = try String(decoding: JSONEncoder().encode(fixture.absoluteString), as: UTF8.self)
    _ = try await evaluate(
      id, "(()=>{setTimeout(()=>location.href=\(address),0);return {scheduled:true}})()")
    var blocked = false
    var loaded = false
    for _ in 0..<100 {
      let failure = runtime.privatePrivacyStatus(forProbeTabID: id)?["failure"] as? [String: Any]
      if let value = try? await evaluate(id, "({instance:window.arcusisInstance})"),
        value["instance"] is String
      {
        loaded = true
        break
      }
      if failure?["code"] as? Int == -20 {
        blocked = true
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    let closed: Bool = await withCheckedContinuation { continuation in
      runtime.closePrivateTabID(id, windowID: windowID, contextID: contextID) {
        continuation.resume(returning: $0)
      }
    }
    return acknowledged && loaded && !blocked && closed
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
      (async()=>{const r={};await fetch('/private-privacy/cookie',{credentials:'include'});
      const v=await (await fetch('/private-privacy/cookie',{credentials:'include'})).json();r.cookieReturned=v.cookie.includes('privacyHttp=1');
      for(const [key,host] of [['tracker','tracker.localhost'],['otherHTTP','localhost']]){
        try{const q=await fetch('http://'+host+':\(port)/private-privacy/resource');r[key]=q.ok&&(await q.json()).fixture==='privacy'}catch{r[key]=false}
      }return r})()
      """
  }

  private func evaluate(_ tab: String, _ script: String) async throws -> [String: Any] {
    let json: String? = await withCheckedContinuation { continuation in
      runtime.evaluatePrivacyProbeTabID(tab, script: script) { continuation.resume(returning: $0) }
    }
    guard let json, let data = json.data(using: .utf8),
      let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw PrivateWindowFailure("Private privacy script did not return an object.") }
    return result
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
        "globalCookieAndStorageBlock": "unsupported",
        "trackerAndThirdPartyRequestBlocking": "unsupported",
        "engineWideHTTPSOnly": "unsupported",
        "privateReferrerAndWebRTCPolicy": "unsupported",
        "disablePreviouslyPermittedPrivateExtensions": "unsupported",
      ],
      "checks": checks, "observations": observations, "error": error as Any? ?? NSNull(),
      "limits": [
        "Global OTR cookie/storage defaults cannot be set; per-origin navigation guards do not cover every redirect, page link, frame or worker.",
        "CDP auto-detaches when idle, dropping network rules and cookie overrides. Tracker blocking, blanket third-party blocking and forced HTTPS cannot be enforced.",
        "Referrer and WebRTC policy are outside the host preference allowlist. Process-wide switches would affect regular browsing.",
        "Previously incognito-enabled extensions cannot be disabled through an OTR-only API.",
      ],
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: root.appending(path: "\(phase)-private-privacy.json"), options: .atomic)
  }
}

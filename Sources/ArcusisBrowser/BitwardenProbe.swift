import AppKit
import BrowserCore
import ChromiumBridge
import Foundation
import SwiftUI

/// Opt-in public-store test in an empty disposable profile. Never enters vault credentials.
@MainActor
final class BitwardenProbe {
  private let runtime: ARCChromiumRuntime
  private let engine: BrowserEngine
  private let store: BrowserStore
  private let root: URL
  private let fixture: URL
  private let phase: String
  private let onboardingControl: Bool
  private let extensionID = "nngceckbapebfimnlniiiahkandclblb"
  private var checks: [String] = []
  private var popupWindow: NSWindow?
  private var consentWindow: NSWindow?

  init(
    runtime: ARCChromiumRuntime, engine: BrowserEngine, store: BrowserStore,
    root: URL, fixture: URL, phase: String, onboardingControl: Bool = false
  ) {
    self.runtime = runtime
    self.engine = engine
    self.store = store
    self.root = root
    self.fixture = fixture
    self.phase = phase
    self.onboardingControl = onboardingControl
  }

  func run() async throws -> [String] {
    do { return try await exercise() } catch {
      try? write(
        [
          "passed": false, "error": error.localizedDescription, "checks": checks,
          "phase": phase,
          "controlOnly": onboardingControl, "firstClickAcceptancePassed": false,
          "scope": "Disposable real-store test. No vault credentials entered.",
        ],
        name: "\(phase)-bitwarden.json")
      throw error
    }
  }

  private func exercise() async throws -> [String] {
    if let existing = store.session.spaces.first(where: { $0.name == "Bitwarden store probe" }) {
      store.perform(.space(existing.id))
    } else {
      guard store.createSpace(name: "Bitwarden store probe", sharingProfile: nil, tint: .rose)
      else {
        throw BitwardenProbeFailure("Could not create a disposable Bitwarden profile.")
      }
    }
    let profile = store.session.selectedSpace.profileID
    if phase == "initial" {
      let address = URL(
        string: "https://chromewebstore.google.com/detail/bitwarden-password-manager/\(extensionID)"
      )!
      store.perform(.open(address))
      let tab = store.session.selectedSpace.selectedTabID!.uuidString
      var page: [String: Any] = [:]
      var buttonReady = false
      for _ in 0..<120 {
        page =
          await evaluate(
            tab,
            """
            ({url:location.href, text:document.body?.innerText?.slice(0,20000),
              buttons:[...document.querySelectorAll('button,[role="button"]')].map(b=>
                ({text:(b.innerText || b.getAttribute('aria-label') || '').trim(), disabled:b.disabled || b.getAttribute('aria-disabled')==='true'}))})
            """) ?? [:]
        if let buttons = page["buttons"] as? [[String: Any]],
          buttons.contains(where: {
            ($0["text"] as? String)?.lowercased() == "add to chrome"
              && $0["disabled"] as? Bool != true
          })
        {
          buttonReady = true
          break
        }
        try await Task.sleep(for: .milliseconds(250))
      }
      try write(page, name: "bitwarden-store-page.json")
      let picture: Data? = await withCheckedContinuation { continuation in
        runtime.captureProbeTabID(tab) { continuation.resume(returning: $0) }
      }
      try picture?.write(to: root.appending(path: "bitwarden-store.png"), options: .atomic)
      guard buttonReady else {
        throw BitwardenProbeFailure(
          "Chrome Web Store did not offer an enabled Add to Chrome button. See bitwarden-store-page.json."
        )
      }
      _ = await evaluate(
        tab,
        """
        (()=>{const b=[...document.querySelectorAll('button,[role="button"]')].find(b=>
          (b.innerText || b.getAttribute('aria-label') || '').trim().toLowerCase()==='add to chrome');
          b?.click();return {clicked:!!b};})()
        """, userGesture: true)
      var consent: ExtensionInstallRequest?
      for _ in 0..<120 {
        consent = store.installationRequests.first { $0.browserExtension.id == extensionID }
        if consent != nil { break }
        try await Task.sleep(for: .milliseconds(250))
      }
      guard let consent else {
        throw BitwardenProbeFailure(
          "Store action did not reach native consent: \(engine.notice ?? "no native notice")")
      }
      try expect(
        consent.profileID == profile && consent.tabID.uuidString == tab,
        "real Bitwarden store consent targets its disposable profile and source tab")
      try write(
        [
          "id": consent.browserExtension.id, "name": consent.browserExtension.name,
          "version": consent.browserExtension.version, "permissions": consent.permissions,
          "sourceURL": consent.sourceURL.absoluteString, "profileID": profile.uuidString,
        ],
        name: "bitwarden-store-consent.json")
      try await captureConsent(consent)
      store.resolveInstallation(consent.id, accepted: true)
    }
    var installed: [String: Any]?
    for _ in 0..<160 {
      installed = runtime.extensions(forProfileID: profile.uuidString).first {
        $0["id"] as? String == extensionID
      }
      if installed != nil { break }
      try await Task.sleep(for: .milliseconds(250))
    }
    guard let installed else {
      throw BitwardenProbeFailure("The signed store extension was not registered in its profile.")
    }
    try expect(true, "\(phase) Bitwarden is registered as a non-component store extension")
    store.perform(.open(fixture))
    let tab = store.session.selectedSpace.selectedTabID!.uuidString
    for _ in 0..<80 {
      if runtime.view(forTabID: tab) != nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    engine.refreshExtensions()
    engine.executeExtension(extensionID)
    guard case .popup(var popup) = engine.extensionPanel else {
      throw BitwardenProbeFailure(
        "Bitwarden did not open its native-hosted popup: \(engine.notice ?? "no native notice")")
    }
    try expect(
      popup.profileID == profile && popup.tabID.uuidString == tab,
      "Bitwarden popup retains the selected profile and page target")
    attachHiddenPopup(popup.id)
    var popupState: [String: Any] = [:]
    var ready = false
    var welcomeNavigations = 0
    var skippedSetup = false
    var openedLogin = false
    var transitions: [[String: Any]] = []
    let clock = ContinuousClock()
    var lastRoute = ""
    var routeChangedAt = clock.now
    for _ in 0..<160 {
      if store.session.selectedSpace.selectedTabID?.uuidString != tab {
        let selected = store.session.selectedSpace
        guard selected.profileID == profile, welcomeNavigations < 2,
          selected.selectedTab?.url.host() == "bitwarden.com",
          selected.selectedTab?.url.path().hasPrefix("/browser-start") == true,
          let owner = store.session.spaces.first(where: {
            $0.tabs.contains { $0.id.uuidString == tab }
          }),
          let tabID = UUID(uuidString: tab)
        else {
          throw BitwardenProbeFailure(
            "An unexpected page/profile replaced the Bitwarden probe context.")
        }
        welcomeNavigations += 1
        transitions.append([
          "event": "welcome-tab", "url": selected.selectedTab!.url.absoluteString,
        ])
        try expect(
          runtime.view(forExtensionPopupID: popup.id) == nil,
          "Bitwarden welcome navigation closes the popup in its original context")
        store.perform(.tab(space: owner.id, tab: tabID))
        engine.executeExtension(extensionID)
        guard case .popup(let reopened) = engine.extensionPanel else {
          throw BitwardenProbeFailure("Could not reopen Bitwarden after its welcome navigation.")
        }
        popup = reopened
        skippedSetup = false
        openedLogin = false
        attachHiddenPopup(popup.id)
      }
      let json: String? = await withCheckedContinuation { continuation in
        runtime.evaluateProbePopupID(
          popup.id,
          script: """
            ({url:location.href,title:document.title,text:document.body?.innerText?.slice(0,12000),
              html:document.body?.innerHTML?.slice(0,12000),visibility:document.visibilityState,
              apiDiagnostics:window.arcusisAPIDiagnostics,hash:location.hash,
              extensionID:chrome.runtime.id,inputs:[...document.querySelectorAll('input')].map(i=>i.type)})
            """
        ) { continuation.resume(returning: $0) }
      }
      if let data = json?.data(using: .utf8),
        let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      {
        popupState = state
        let text = (state["text"] as? String ?? "").lowercased()
        let address = state["url"] as? String ?? ""
        if address != lastRoute {
          lastRoute = address
          routeChangedAt = clock.now
          transitions.append(["event": "route", "url": address, "text": state["text"] ?? ""])
        }
        let requiredAge: Duration =
          onboardingControl && address.contains("#/intro-carousel")
          ? .seconds(2) : .milliseconds(500)
        if clock.now - routeChangedAt < requiredAge {
          try await Task.sleep(for: .milliseconds(100))
          continue
        }
        if address.contains("#/default-password-manager-prompt") && !skippedSetup {
          skippedSetup = await clickPopupButton(popup.id, title: "Skip")
          transitions.append(["event": "skip-input", "dispatched": skippedSetup, "url": address])
          if skippedSetup {
            try expect(
              true, "skips optional password-manager settings change in the disposable profile")
          }
          try await Task.sleep(for: .milliseconds(100))
          continue
        }
        if text.contains("log in") && !openedLogin
          && !(state["inputs"] as? [String] ?? []).contains("email")
        {
          openedLogin = await clickPopupButton(popup.id, title: "Log in")
          let age = (clock.now - routeChangedAt).components
          transitions.append([
            "event": "login-input", "dispatched": openedLogin, "url": address,
            "controlOnly": onboardingControl,
            "requiredScreenAgeMilliseconds": requiredAge == .seconds(2) ? 2000 : 500,
            "observedScreenAgeMilliseconds": age.seconds * 1000 + age.attoseconds
              / 1_000_000_000_000_000,
          ])
          if openedLogin {
            try expect(true, "clicks Log in in the current Bitwarden popup instance")
          }
          try await Task.sleep(for: .milliseconds(100))
          continue
        }
        if state["extensionID"] as? String == extensionID
          && text.contains("email") && (state["inputs"] as? [String] ?? []).contains("email")
        {
          ready = true
          break
        }
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    popupState["probeInteractions"] = [
      "controlOnly": onboardingControl,
      "popupID": popup.id, "openedLogin": openedLogin,
      "skippedSetup": skippedSetup, "welcomeNavigations": welcomeNavigations,
      "transitions": transitions,
    ]
    try write(popupState, name: "\(phase)-bitwarden-popup.json")
    if !ready {
      // The readiness result is already fixed as a failure. A second ordinary
      // click happens before diagnostic API reads or opening a diagnostic tab.
      // It cannot turn the original gate green.
      let secondClick = await clickPopupButton(popup.id, title: "Log in")
      try await Task.sleep(for: .seconds(1))
      let after: String? = await withCheckedContinuation { continuation in
        runtime.evaluateProbePopupID(
          popup.id,
          script:
            "({url:location.href,text:document.body?.innerText,inputs:[...document.querySelectorAll('input')].map(i=>i.type)})"
        ) { continuation.resume(returning: $0) }
      }
      try write(
        ["dispatched": secondClick, "after": after ?? "unavailable", "readinessPassed": false],
        name: "\(phase)-bitwarden-second-click.json")
      // Diagnostic API reads must never initialize a lazy service in time to
      // turn the readiness test or the second-click diagnostic into a pass.
      await queryPopupAPIs(popup.id)
      try await Task.sleep(for: .milliseconds(500))
      let diagnostic: String? = await withCheckedContinuation { continuation in
        runtime.evaluateProbePopupID(
          popup.id, script: "({api:window.arcusisAPIDiagnostics,text:document.body?.innerText})"
        ) {
          continuation.resume(returning: $0)
        }
      }
      if let data = diagnostic?.data(using: .utf8) {
        try data.write(
          to: root.appending(path: "\(phase)-bitwarden-api-diagnostic.json"), options: .atomic)
      }
      try await collectExtensionErrors(profile: profile)
    }
    guard ready else {
      throw BitwardenProbeFailure("Bitwarden popup did not reach its signed-out login UI.")
    }
    try expect(
      true,
      "\(phase) actual Bitwarden popup reaches its email login form without entering credentials")
    let screenshot: Data? = await withCheckedContinuation { continuation in
      runtime.captureProbePopupID(popup.id) { continuation.resume(returning: $0) }
    }
    try screenshot?.write(to: root.appending(path: "\(phase)-bitwarden.png"), options: .atomic)
    try write(
      [
        "passed": true, "installed": installed, "checks": checks,
        "phase": phase,
        "controlOnly": onboardingControl, "firstClickAcceptancePassed": !onboardingControl,
        "scope":
          "Store install and signed-out popup only. No vault login, unlock, autofill, Touch ID, passkeys, or native messaging tested.",
      ],
      name: "\(phase)-bitwarden.json")
    engine.extensionPanel = nil
    return checks
  }

  private func evaluate(_ tab: String, _ script: String, userGesture: Bool = false) async
    -> [String: Any]?
  {
    let json: String? = await withCheckedContinuation { continuation in
      if userGesture {
        runtime.evaluateProbeUserGesture(inTabID: tab, script: script) {
          continuation.resume(returning: $0)
        }
      } else {
        runtime.evaluate(inTabID: tab, script: script) { continuation.resume(returning: $0) }
      }
    }
    guard let data = json?.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func write(_ object: [String: Any], name: String) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
      .write(to: root.appending(path: name), options: .atomic)
  }

  private func attachHiddenPopup(_ id: String) {
    guard let page = runtime.view(forExtensionPopupID: id) else { return }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = page
    page.frame = NSRect(x: 0, y: 0, width: 480, height: 600)
    popupWindow = window
  }

  private func clickPopupButton(_ id: String, title: String) async -> Bool {
    await withCheckedContinuation { continuation in
      runtime.clickProbePopupID(id, buttonTitle: title) { continuation.resume(returning: $0) }
    }
  }

  private func captureConsent(_ request: ExtensionInstallRequest) async throws {
    let host = NSHostingView(
      rootView: ExtensionConsent(store: store, request: request)
        .frame(width: 516, height: 480).environment(\.colorScheme, .light))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 516, height: 480),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    consentWindow = window
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?.write(
      to: root.appending(path: "bitwarden-native-consent.png"), options: .atomic)
  }

  private func collectExtensionErrors(profile: UUID) async throws {
    let tab = UUID().uuidString
    try runtime.openTabID(tab, profileID: profile.uuidString, url: "chrome://extensions")
    for _ in 0..<40 {
      let started = await evaluate(
        tab,
        """
        (()=>{if(!chrome.developerPrivate?.getExtensionsInfo)return {ready:false};
          window.arcusisExtensionErrors=null;
          chrome.developerPrivate.getExtensionsInfo({includeDisabled:true,includeTerminated:true},items=>{
            window.arcusisExtensionErrors=items.filter(i=>i.id==='\(extensionID)').map(i=>
              ({id:i.id,state:i.state,location:i.location,runtimeErrors:i.runtimeErrors,
                manifestErrors:i.manifestErrors,views:i.views}));});return {ready:true};})()
        """)
      if started?["ready"] as? Bool == true { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    for _ in 0..<40 {
      if let info = await evaluate(tab, "({extensions:window.arcusisExtensionErrors})"),
        info["extensions"] is [Any]
      {
        try write(info, name: "\(phase)-bitwarden-extension-errors.json")
        break
      }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  private func queryPopupAPIs(_ id: String) async {
    let _: String? = await withCheckedContinuation { continuation in
      runtime.evaluateProbePopupID(
        id,
        script: """
          (()=>{window.arcusisAPIDiagnostics={};
            const save=(name,work)=>Promise.resolve().then(work).then(value=>window.arcusisAPIDiagnostics[name]=value,
              error=>window.arcusisAPIDiagnostics[name]={error:String(error)});
            save('window',async()=>{const w=await chrome.windows.getCurrent({populate:true});return {id:w.id,focused:w.focused,tabs:w.tabs?.map(t=>t.id)};});
            save('lastWindow',async()=>{const w=await chrome.windows.getLastFocused();return {id:w.id,focused:w.focused};});
            save('localKeys',async()=>Object.keys(await chrome.storage.local.get(null)));
            save('introDismissed',async()=>await chrome.storage.local.get('global_vaultBrowserIntroCarousel_introCarouselDismissed'));
            save('sessionKeys',async()=>Object.keys(await chrome.storage.session.get(null)));
            save('managedKeys',async()=>Object.keys(await chrome.storage.managed.get(null)));
            save('contexts',async()=>(await chrome.runtime.getContexts({})).map(c=>({type:c.contextType,origin:c.documentOrigin})));
            return true;})()
          """
      ) { continuation.resume(returning: $0) }
    }
  }

  private func expect(_ condition: Bool, _ name: String) throws {
    guard condition else { throw BitwardenProbeFailure(name) }
    checks.append(name)
  }
}

private struct BitwardenProbeFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

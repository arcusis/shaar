// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import ChromiumBridgeVerification

@testable import ArcusisBrowser

/// Real engine hosts, disposable profiles and authored popup callbacks. No credentials or OS input.
@MainActor
final class ProfileOnboardingProbe {
  let host: NativeBrowserHost
  let root: URL
  let fixture: URL
  private var runtime: ARCChromiumRuntime { host.events.runtime }

  init(host: NativeBrowserHost, root: URL, fixture: URL) {
    self.host = host
    self.root = root
    self.fixture = fixture
  }

  func run(live: Bool = false, options: [AccountSignInOption] = AccountSignInOption.allCases)
    async throws -> [String]
  {
    var checks: [String] = []
    let before = host.workspace.workspace
    for option in options {
      let provider = option.provider
      host.presentNewProfile()
      guard let model = host.profileOnboarding?.model else { throw Failure("Onboarding missing") }
      model.name = "Fixture \(provider.title)"
      for _ in 0..<3 { model.continueToNext() }
      model.connect(option: option)
      guard let flow = host.accountSignIns.values.first(where: { $0.profileID == model.profileID }),
        let tab = flow.store.session.selectedSpace.selectedTabID
      else { throw Failure("Sign-in host missing") }
      defer { model.cancel() }
      guard !flow.window.isVisible else { throw Failure("Sign-in window became visible") }
      try await wait("draft browser tab") {
        self.runtime.windowID(forTabID: tab.uuidString) == flow.engine.windowID
      }
      if live {
        try await verifyProviderPage(flow: flow, tab: tab, option: option)
        checks.append("\(option.title): provider-owned sign-in page reached without credentials")
      } else {
        guard flow.engine.navigateCurrentPage(to: fixture) else {
          throw Failure("Fixture navigation rejected")
        }
        try await wait("authored sign-in page") {
          let value = await self.value(
            tab, "({ready:document.readyState==='complete',url:location.href})")
          return value?["ready"] as? Bool == true
            && value?["url"] as? String == self.fixture.absoluteString
        }
        if provider != .google {
          try await verifyMetadata(provider: provider, tab: tab)
          checks.append(
            "\(option.title): authored account-menu name, email and photo read by the production session script"
          )
        }
        try await verifyPopup(flow: flow, tab: tab)
        checks.append(
          "\(provider.title): draft popup preserves session, opener and callback; Cancel closes every transient host"
        )
      }
      let windows = flow.windowIDs
      model.cancel()
      guard Self.preservesProfileOwnership(before: before, after: host.workspace.workspace),
        model.outcome == .cancelled,
        host.accountSignIns.isEmpty, host.profileOnboarding == nil,
        windows.allSatisfy({
          runtime.window(forID: $0) == nil || runtime.window(forID: $0)?.isVisible == false
        })
      else { throw Failure("Cancelled sign-in changed saved workspace or leaked a host") }
    }
    guard NSApp.windows.allSatisfy({ !$0.isVisible }) else { throw Failure("Visible probe window") }
    return checks
  }

  /// Existing pages may finish navigating while the draft is open. Their URL/title updates
  /// are independent of onboarding; cancellation must preserve catalog ownership and windows.
  static func preservesProfileOwnership(before: BrowserWorkspace, after: BrowserWorkspace) -> Bool {
    let owners = Dictionary(
      uniqueKeysWithValues: before.catalog.spaces.map { ($0.id, $0.profileID) })
    return after.catalog.profiles == before.catalog.profiles
      && after.catalog.spaces.map(\.id) == before.catalog.spaces.map(\.id)
      && after.catalog.spaces.allSatisfy { owners[$0.id] == $0.profileID }
      && after.windows.map(\.id) == before.windows.map(\.id)
      && after.focusedWindowID == before.focusedWindowID
  }

  private func verifyMetadata(provider: AccountProvider, tab: UUID) async throws {
    let apple = provider == .apple
    let script = """
      (()=>{
        const button=document.createElement('button');button.id=\(apple ? "'fixture-account'" : "'mectrl_main_trigger'");
        const photo=document.createElement('img');photo.src=new URL('/favicon-initial.png',location.href).href;
        if (\(apple ? "true" : "false")) {
          const wrapper=document.createElement('span');wrapper.className='profile-photo';wrapper.append(photo);button.append(wrapper);
        } else {photo.id='mectrl_currentAccount_picture';button.append(photo);}
        button.onclick=()=>{
          const menu=document.createElement('div');menu.className='account-menu';
          menu.innerHTML=\(apple ? "\"<div class='header'><span class='name'>Alex Example</span><span class='email'>alex@example.test</span></div>\"" : "\"<span id='mectrl_currentAccount_primary'>Alex Example</span><span id='mectrl_currentAccount_secondary'>alex@example.test</span>\"");
          document.body.append(menu);
        };
        document.body.append(button);return {};
      })()
      """
    _ = await value(tab, script)
    try await wait("authored provider metadata") {
      guard
        let state = await self.value(
          tab, "JSON.parse(\(SessionAccountPage.readScript(for: provider)))"),
        state["email"] as? String == "alex@example.test",
        state["name"] as? String == "Alex Example",
        let photo = state["photoData"] as? String
      else { return false }
      return SessionAccountPage.photoData(from: photo) != nil
    }
  }

  private func verifyPopup(flow: ProfileAccountSignIn, tab: UUID) async throws {
    var popupTab: UUID?
    let previous = host.events.onNewTabWillAdopt
    host.events.onNewTabWillAdopt = { id, profile, opener in
      previous?(id, profile, opener)
      if profile == flow.profileID.uuidString, opener == tab.uuidString {
        popupTab = UUID(uuidString: id)
      }
    }
    defer { host.events.onNewTabWillAdopt = previous }
    let token = UUID().uuidString
    let origin = Self.origin(of: fixture)
    guard !origin.isEmpty else { throw Failure("Popup fixture has no origin") }
    let address = String(data: try JSONEncoder().encode(fixture.absoluteString), encoding: .utf8)!
    // Install the opener listener in the same renderer task as window.open. A separate evaluate
    // could fail to install it while the later user-gesture evaluation still opened the popup.
    let reply: String? = await withCheckedContinuation { continuation in
      runtime.evaluateProbeUserGesture(
        inTabID: tab.uuidString,
        script: """
          (()=>{
            document.cookie='shaarOnboarding=\(token);path=/';
            window.fixtureReply=null;
            window.addEventListener('message',e=>{
              // A restored renderer can expose a new WindowProxy wrapper for the same opener.
              // Correlate this response by origin and its one-use token instead of source identity.
              if(e.origin===location.origin&&e.data?.type==='shaar-onboarding-callback')
                window.fixtureReply={origin:e.origin,type:e.data.type,token:e.data.token};
            });
            window.fixturePopup=window.open(\(address),'_blank','popup,width=520,height=680');
            return !!window.fixturePopup;
          })()
          """
      ) {
        continuation.resume(returning: $0)
      }
    }
    guard reply == "true" else { throw Failure("Draft popup rejected") }
    try await wait("popup adoption") { popupTab != nil && flow.windowIDs.count == 2 }
    guard let child = popupTab else { throw Failure("Popup tab missing") }
    try await wait("popup session") {
      let state = await self.value(
        child, "({cookie:document.cookie,opener:!!window.opener,ready:document.readyState})")
      return (state?["cookie"] as? String)?.contains("shaarOnboarding=\(token)") == true
        && state?["opener"] as? Bool == true && state?["ready"] as? String == "complete"
    }
    _ = await value(
      child,
      """
      (()=>{window.opener.postMessage(
        {type:'shaar-onboarding-callback',token:'\(token)'},location.origin);return {};})()
      """
    )
    try await wait("popup callback") {
      let reply = await self.value(tab, "window.fixtureReply") as? [String: Any]
      return ProfileOnboardingPopupCallback.matches(reply, origin: origin, token: token)
    }
    guard flow.windowIDs.allSatisfy({ runtime.window(forID: $0)?.isVisible == false }) else {
      throw Failure("Popup show request escaped hidden mode")
    }
  }

  private func verifyProviderPage(
    flow: ProfileAccountSignIn, tab: UUID, option: AccountSignInOption
  ) async throws {
    let provider = flow.provider
    do {
      try await wait("\(provider.title) sign-in page", attempts: 600) {
        guard
          let state = await self.value(
            tab,
            """
            (()=>{
              const frames=Array.from(document.querySelectorAll('iframe')).map(f=>f.src);
              return {url:location.href,ready:document.readyState,
                email:!!document.querySelector('input[type=email],input[name=identifier],input[name=loginfmt]'),frames};
            })()
            """), let address = state["url"] as? String, let url = URL(string: address)
        else { return false }
        if Self.providerPageIsReady(state, provider: provider) { return true }
        if provider == .apple, ["www.icloud.com", "icloud.com"].contains(url.host ?? "") {
          // The provider's own Sign In button opens its auth iframe. No form values are filled.
          _ = await self.value(
            tab,
            "(()=>{const b=document.querySelector('ui-button.sign-in-button,button.sign-in-button,.sign-in-button');if(b)b.click();return {};})()"
          )
        }
        return false
      }
    } catch {
      let state =
        await value(
          tab,
          "({page:location.origin+location.pathname,title:document.title,inputs:Array.from(document.querySelectorAll('input')).map(i=>({id:i.id,type:i.type})),buttons:Array.from(document.querySelectorAll('button,a')).map(e=>(e.textContent||'').trim()).filter(Boolean).slice(0,30)})"
        ) ?? [:]
      let data = try JSONSerialization.data(
        withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: root.appending(path: "provider-\(option.rawValue)-failure.json"))
      let image: Data? = await withCheckedContinuation { continuation in
        runtime.captureProbeTabID(tab.uuidString) { continuation.resume(returning: $0) }
      }
      try image?.write(to: root.appending(path: "provider-\(option.rawValue)-failure.png"))
      throw error
    }
    // Provider transitions and cross-origin auth iframes can paint after the parent is ready.
    try await Task.sleep(for: .seconds(3))
    let data: Data? = await withCheckedContinuation { continuation in
      runtime.captureProbeTabID(tab.uuidString) { continuation.resume(returning: $0) }
    }
    guard let data, !data.isEmpty else { throw Failure("Provider screenshot missing") }
    try data.write(to: root.appending(path: "provider-\(option.rawValue).png"), options: .atomic)
  }

  static func providerPageIsReady(_ state: [String: Any], provider: AccountProvider) -> Bool {
    guard let address = state["url"] as? String, let url = URL(string: address),
      url.scheme == "https", state["ready"] as? String == "complete"
    else { return false }
    let host = url.host ?? ""
    let email = state["email"] as? Bool == true
    switch provider {
    case .google: return host == "accounts.google.com" && email
    case .microsoft: return ["login.microsoftonline.com", "login.live.com"].contains(host) && email
    case .apple:
      if ["appleid.apple.com", "account.apple.com", "idmsa.apple.com"].contains(host) && email {
        return true
      }
      guard ["www.icloud.com", "icloud.com"].contains(host) else { return false }
      return (state["frames"] as? [String] ?? []).contains {
        guard let frame = URL(string: $0) else { return false }
        return frame.scheme == "https" && frame.host == "idmsa.apple.com"
      }
    }
  }

  private func value(_ tab: UUID, _ script: String) async -> [String: Any]? {
    let json: String? = await withCheckedContinuation { continuation in
      runtime.evaluate(inTabID: tab.uuidString, script: script) {
        continuation.resume(returning: $0)
      }
    }
    guard let data = json?.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func wait(_ label: String, attempts: Int = 100, until condition: () async -> Bool)
    async throws
  {
    for _ in 0..<attempts {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw Failure("Timed out: \(label)")
  }

  private static func origin(of url: URL) -> String {
    guard let scheme = url.scheme, let host = url.host else { return "" }
    let port = url.port.map { ":\($0)" } ?? ""
    return "\(scheme)://\(host)\(port)"
  }

  private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
  }
}

extension ProfileOnboardingProbe {
  /// Explicit live smoke mode. Default CI uses only the authored popup fixture above.
  static func runStandalone(arguments: [String]) -> Int32 {
    do {
      guard let index = arguments.firstIndex(of: "--probe-data-dir"),
        arguments.indices.contains(index + 1), let frameworks = Bundle.main.privateFrameworksURL
      else { throw Failure("Missing disposable provider probe directory or bundled engine") }
      let root = URL(filePath: arguments[index + 1]).standardizedFileURL.resolvingSymlinksInPath()
      let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      guard root.path.hasPrefix(temporary.path + "/"),
        root.lastPathComponent.hasPrefix("arcusis-engine-probe-"),
        try String(contentsOf: root.appending(path: ".arcusis-probe"), encoding: .utf8)
          == "arcusis-engine-probe-v1\n"
      else { throw Failure("Provider probe requires a marked temporary directory") }
      let live = arguments.contains("--probe-profile-providers")
      var fixture = URL(string: "http://127.0.0.1:1/")!
      if !live {
        guard let index = arguments.firstIndex(of: "--probe-url"),
          arguments.indices.contains(index + 1), let url = URL(string: arguments[index + 1]),
          url.scheme == "http", url.host == "127.0.0.1", url.port != nil
        else { throw Failure("Profile fixture requires an authored loopback page") }
        fixture = url
      }
      let runtime = try ARCChromiumRuntime(
        frameworkURL: frameworks.appending(path: "Chromium Framework.framework"))
      let workspace = try BrowserWorkspaceStore(
        file: WorkspaceFile(
          url: root.appending(path: "workspace.json"),
          legacySessionURL: root.appending(path: "session.json")))
      let host = NativeBrowserHost(
        events: BrowserRuntimeEvents(runtime: runtime), workspace: workspace,
        preferences: BrowserPreferencesStore(fileURL: root.appending(path: "preferences.json")),
        presentation: .hiddenProbe, usesPrimaryWindow: false)
      var passed = false
      var finished = false
      func finish(_ checks: [String], error: String?) {
        guard !finished else { return }
        finished = true
        passed = error == nil
        let report: [String: Any] = [
          "passed": passed, "checks": checks, "error": error ?? "",
          "credentialsUsed": false, "visibleWindows": NSApp.windows.filter(\.isVisible).count,
        ]
        if let data = try? JSONSerialization.data(
          withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        {
          try? data.write(to: root.appending(path: "providers.json"), options: .atomic)
        }
        host.detach()
        runtime.quit()
      }
      runtime.onReady = {
        Task { @MainActor in
          do {
            try host.restore()
            let checks = try await ProfileOnboardingProbe(
              host: host, root: root,
              fixture: fixture
            ).run(live: live)
            finish(checks, error: nil)
          } catch { finish([], error: error.localizedDescription) }
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 240) {
        finish([], error: "Provider probe timed out")
      }
      let code = runtime.run(withDataDirectory: root.appending(path: "Chromium"), testing: true)
      return passed ? code : 1
    } catch {
      FileHandle.standardError.write(Data("Provider probe: \(error.localizedDescription)\n".utf8))
      return 1
    }
  }
}

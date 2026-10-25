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
  private let vaultCredentials: VaultProbeCredentials?
  private let spaceName: String
  private let extensionID = "nngceckbapebfimnlniiiahkandclblb"
  private var checks: [String] = []
  private var vaultStageResults: [String: Bool] = [:]
  private enum VaultStage: String {
    case notStarted = "not-started"
    case storePage = "store-page"
    case storeAction = "store-action"
    case storeConsent = "store-consent"
    case storeInstallation = "store-installation"
    case popup, onboarding, environment, login
    case sharedProfile = "shared-profile"
    case lockUnlock = "lock-unlock"
    case completed
  }
  private var vaultStage = VaultStage.notStarted
  private var popupWindow: NSWindow?
  private var consentWindow: NSWindow?

  init(
    runtime: ARCChromiumRuntime, engine: BrowserEngine, store: BrowserStore,
    root: URL, fixture: URL, phase: String, onboardingControl: Bool = false,
    spaceName: String = "Bitwarden store probe", vaultCredentials: VaultProbeCredentials? = nil
  ) {
    self.runtime = runtime
    self.engine = engine
    self.store = store
    self.root = root
    self.fixture = fixture
    self.phase = phase
    self.onboardingControl = onboardingControl
    self.spaceName = spaceName
    self.vaultCredentials = vaultCredentials
  }

  func run() async throws -> [String] {
    do { return try await exercise() } catch {
      try? write(
        [
          "passed": false,
          "error": vaultCredentials == nil ? error.localizedDescription : "Vault UI stage failed.",
          "checks": vaultCredentials == nil ? checks : [],
          "phase": phase,
          "controlOnly": onboardingControl, "firstClickAcceptancePassed": false,
          "scope": vaultCredentials == nil
            ? "Disposable real-store test. No vault credentials entered."
            : "Redacted control-only vault UI probe.",
        ],
        name: "\(phase)-bitwarden.json")
      if vaultCredentials != nil { try? writeVaultResult(passed: false) }
      throw error
    }
  }

  private func exercise() async throws -> [String] {
    if let vaultCredentials { return try await exerciseVault(vaultCredentials) }
    if let existing = store.session.spaces.first(where: { $0.name == spaceName }) {
      store.perform(.space(existing.id))
    } else {
      guard store.createSpace(name: spaceName, sharingProfile: nil, tint: .rose)
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
      let popupScript = """
        ({url:location.href,title:document.title,text:document.body?.innerText?.slice(0,12000),
          html:document.body?.innerHTML?.slice(0,12000),visibility:document.visibilityState,
          apiDiagnostics:window.arcusisAPIDiagnostics,hash:location.hash,
          extensionID:chrome.runtime.id,inputs:[...document.querySelectorAll('input')].map(i=>i.type)})
        """
      let json: String? = await withCheckedContinuation { continuation in
        runtime.evaluateProbePopupID(
          popup.id,
          script: popupScript
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

  private func captureConsent(_ request: ExtensionInstallRequest, capture: Bool = true) async throws
  {
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
    guard capture else { return }
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

  private func runVaultLogin(
    _ credentials: VaultProbeCredentials.Account, popupID: String, expectedAccount: String,
    label: String
  )
    async throws
    -> Bool
  {
    let driver = BitwardenVaultProbe(runtime: runtime, popupID: popupID)
    guard await prepareVaultLogin(driver),
      let initial = await driver.state(expectedAccount: expectedAccount)
    else { return false }
    if phase == "restart" {
      let locked = initial.passwordFields > 0 && !initial.vaultVisible
      vaultStageResults["restart-locked-\(label)"] = locked
      guard locked else { return false }
    } else if initial.emailFields > 0 {
      guard await driver.fillEmail(credentials.email) else { return false }
      if initial.passwordFields == 0 {
        let fresh = await driver.state()
        let button = fresh?.continueButton == true ? "Continue" : "Log in"
        guard await driver.click(button), await driver.waitFor({ $0.passwordFields > 0 }) else {
          return false
        }
      }
    }
    guard let passwordScreen = await driver.state(expectedAccount: expectedAccount),
      passwordScreen.passwordFields > 0,
      await driver.fillPassword(credentials.masterPassword)
    else { return false }
    let button = passwordScreen.unlockButton ? "Unlock" : "Log in"
    guard await driver.click(button) else { return false }
    let authenticated = await driver.waitFor(
      { $0.vaultVisible && $0.accountIdentityMatches }, seconds: 60,
      expectedAccount: expectedAccount)
    vaultStageResults["account-\(label)-identity-matches"] = authenticated
    if phase == "restart" {
      vaultStageResults["restart-unlock-\(label)"] = authenticated
    }
    return authenticated
  }

  private func prepareVaultLogin(_ driver: BitwardenVaultProbe) async -> Bool {
    var introObservedAt: ContinuousClock.Instant?
    let clock = ContinuousClock()
    for _ in 0..<100 {
      guard let current = await driver.state() else {
        try? await Task.sleep(for: .milliseconds(250))
        continue
      }
      if phase == "initial", onboardingControl, current.introCarousel {
        let now = clock.now
        if introObservedAt == nil { introObservedAt = now }
        guard let introObservedAt, now - introObservedAt >= .seconds(2) else {
          try? await Task.sleep(for: .milliseconds(100))
          continue
        }
        vaultStageResults["onboarding-control"] = true
      } else if phase == "initial", onboardingControl {
        introObservedAt = nil
      }
      if current.emailFields > 0 || current.passwordFields > 0 || current.vaultVisible {
        return true
      }
      if current.skipPrompt {
        _ = await driver.click("Skip")
      } else if current.loginPrompt {
        _ = await driver.click("Log in")
      }
      try? await Task.sleep(for: .milliseconds(250))
    }
    return false
  }

  private func unlockVault(
    _ driver: BitwardenVaultProbe, credentials: VaultProbeCredentials.Account,
    expectedAccount: String
  ) async -> Bool {
    guard let state = await driver.state(expectedAccount: expectedAccount),
      state.passwordFields > 0, state.unlockButton,
      await driver.fillPassword(credentials.masterPassword), await driver.click("Unlock")
    else { return false }
    return await driver.waitFor(
      { $0.vaultVisible && $0.accountIdentityMatches }, seconds: 60,
      expectedAccount: expectedAccount)
  }

  private func lockVault(_ driver: BitwardenVaultProbe, accountEmail: String) async -> Bool {
    guard await driver.click("Bitwarden account \(accountEmail)"),
      await driver.waitFor({ $0.lockNowButton }), await driver.click("Lock now")
    else { return false }
    return await driver.waitFor({ $0.passwordFields > 0 && !$0.vaultVisible })
  }

  private func verifySharedAlpha(expectedAccount: String) async throws -> Bool {
    guard let account = store.session.spaces.first(where: { $0.name == "Account Alpha" }),
      let shared = store.session.spaces.first(where: { $0.name == "Shared Alpha" }),
      shared.profileID == account.profileID
    else { return false }
    engine.extensionPanel = nil
    store.perform(.space(shared.id))
    guard let popup = try await openVaultPopup() else { return false }
    let state = await BitwardenVaultProbe(runtime: runtime, popupID: popup)
      .state(expectedAccount: expectedAccount)
    engine.extensionPanel = nil
    store.perform(.space(account.id))
    return state?.vaultVisible == true && state?.accountIdentityMatches == true
  }

  private func exerciseVault(_ credentials: VaultProbeCredentials) async throws -> [String] {
    let labels = [("alpha", "Account Alpha"), ("beta", "Account Beta")]
    for (label, spaceName) in labels {
      guard let space = store.session.spaces.first(where: { $0.name == spaceName }) else {
        throw BitwardenProbeFailure("Required isolated account Space is missing.")
      }
      store.perform(.space(space.id))
      let profile = space.profileID
      if phase == "initial" { try await installVaultExtension(profile: profile) }
      if phase == "initial", label == "alpha" { store.perform(.open(fixture)) }
      guard
        runtime.extensions(forProfileID: profile.uuidString).contains(where: {
          $0["id"] as? String == extensionID
        })
      else { throw BitwardenProbeFailure("Bitwarden is not registered in an account profile.") }
      vaultStage = .popup
      guard var popupID = try await openVaultPopup() else {
        throw BitwardenProbeFailure("Bitwarden popup did not open for an account profile.")
      }
      let driver = BitwardenVaultProbe(runtime: runtime, popupID: popupID)
      if phase == "initial" {
        vaultStage = .onboarding
        let signedOut = await prepareVaultLogin(driver)
        vaultStageResults["signed-out-\(label)"] = signedOut
        try writeVaultAccountReport(label: label, signedOut: signedOut, authenticated: false)
        vaultStage = .environment
        guard signedOut, await driver.configureSelfHostedServer(credentials.serverURL) else {
          vaultStageResults["self-hosted-server-\(label)"] = false
          try writeVaultResult(passed: false)
          throw BitwardenProbeFailure("Self-hosted server UI configuration is unavailable.")
        }
        vaultStageResults["self-hosted-server-\(label)"] = true
      }
      let account = credentials.accounts[label == "alpha" ? 0 : 1]
      let otherAccount = credentials.accounts[label == "alpha" ? 1 : 0]
      vaultStage = .login
      let authenticated = try await runVaultLogin(
        account, popupID: popupID, expectedAccount: account.email, label: label)
      vaultStageResults["account-\(label)-login"] = authenticated
      guard authenticated else {
        try writeVaultResult(passed: false)
        throw BitwardenProbeFailure("Bitwarden account UI flow failed.")
      }
      if label == "alpha" {
        vaultStage = .sharedProfile
        let sharedAuthenticated = try await verifySharedAlpha(expectedAccount: account.email)
        vaultStageResults["shared-alpha-space-retains-profile"] = sharedAuthenticated
        guard let reopened = try await openVaultPopup() else {
          throw BitwardenProbeFailure("Bitwarden popup did not reopen in Account Alpha.")
        }
        popupID = reopened
      }
      let activeDriver = BitwardenVaultProbe(runtime: runtime, popupID: popupID)
      if let otherIdentity = await activeDriver.state(expectedAccount: otherAccount.email) {
        vaultStageResults["account-\(label)-cross-profile-mismatch"] =
          authenticated && !otherIdentity.accountIdentityMatches
      } else {
        vaultStageResults["account-\(label)-cross-profile-mismatch"] = false
      }
      if phase == "initial" {
        vaultStage = .lockUnlock
        let locked: Bool
        if authenticated {
          locked = await lockVault(activeDriver, accountEmail: account.email)
        } else {
          locked = false
        }
        vaultStageResults["initial-locked-\(label)"] = locked
        let unlocked: Bool
        if locked {
          unlocked = await unlockVault(
            activeDriver, credentials: account, expectedAccount: account.email)
        } else {
          unlocked = false
        }
        vaultStageResults["initial-unlock-\(label)"] = unlocked
        let relocked: Bool
        if unlocked {
          relocked = await lockVault(activeDriver, accountEmail: account.email)
        } else {
          relocked = false
        }
        vaultStageResults["initial-restart-locked-\(label)"] = relocked
      }
      if phase == "initial" {
        try writeVaultAccountReport(
          label: label,
          signedOut: vaultStageResults["signed-out-\(label)"] == true,
          authenticated: authenticated)
      }
      engine.extensionPanel = nil
    }
    if phase == "initial" {
      vaultStageResults["onboarding-control"] = vaultStageResults["onboarding-control"] ?? false
    }
    vaultStageResults["separate-profile-isolation"] =
      store.session.spaces.first(where: { $0.name == "Account Alpha" })?.profileID
      != store.session.spaces.first(where: { $0.name == "Account Beta" })?.profileID
    vaultStageResults["first-click-compatibility"] = false
    let passed = VaultProbeStageAcceptance.accepts(phase: phase, stages: vaultStageResults)
    if passed { vaultStage = .completed }
    try writeVaultResult(passed: passed)
    guard passed else { throw BitwardenProbeFailure("Required Bitwarden vault stage failed.") }
    return [
      "Bitwarden vault flow ran in control-only mode",
      "First-click acceptance remains false pending parent verification",
    ]
  }

  private func installVaultExtension(profile: UUID) async throws {
    vaultStage = .storePage
    let address = URL(
      string: "https://chromewebstore.google.com/detail/bitwarden-password-manager/\(extensionID)"
    )!
    store.perform(.open(address))
    guard store.session.selectedSpace.profileID == profile,
      let selectedTab = store.session.selectedSpace.selectedTab,
      store.session.spaces.contains(where: {
        $0.profileID == profile && $0.tabs.contains(where: { $0.id == selectedTab.id })
      })
    else { throw BitwardenProbeFailure("Store tab is not owned by selected account profile.") }
    let sourceTab = selectedTab.id.uuidString
    var buttonReady = false
    for _ in 0..<120 {
      guard store.session.selectedSpace.profileID == profile,
        store.session.selectedSpace.selectedTabID == selectedTab.id,
        store.session.spaces.contains(where: {
          $0.profileID == profile && $0.tabs.contains(where: { $0.id == selectedTab.id })
        })
      else { throw BitwardenProbeFailure("Store tab left its selected account profile.") }
      guard runtime.nativeTabID(forID: sourceTab) >= 0 else {
        try await Task.sleep(for: .milliseconds(250))
        continue
      }
      let page = await evaluate(
        sourceTab,
        """
        ({ready:[...document.querySelectorAll('button,[role="button"]')].some(b=>(b.innerText||b.getAttribute('aria-label')||'').trim().toLowerCase()==='add to chrome'&& !b.disabled)})
        """)
      if page?["ready"] as? Bool == true {
        buttonReady = true
        break
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    guard buttonReady else { throw BitwardenProbeFailure("Store install action is unavailable.") }
    vaultStage = .storeAction
    _ = await evaluate(
      sourceTab,
      """
      (()=>{const b=[...document.querySelectorAll('button,[role="button"]')].find(b=>(b.innerText||b.getAttribute('aria-label')||'').trim().toLowerCase()==='add to chrome');b?.click();return !!b})()
      """,
      userGesture: true)
    vaultStage = .storeConsent
    var request: ExtensionInstallRequest?
    for _ in 0..<120 {
      request = store.installationRequests.first { $0.browserExtension.id == extensionID }
      if request?.profileID == profile { break }
      request = nil
      try await Task.sleep(for: .milliseconds(250))
    }
    guard let request, request.tabID.uuidString == sourceTab,
      request.profileID == profile, request.matches(store.session),
      store.sheet?.id == BrowserSheet.extensionInstall(request).id
    else { throw BitwardenProbeFailure("Store consent was not presented in its owning profile.") }
    try await captureConsent(request, capture: false)
    store.resolveInstallation(request.id, accepted: true)
    vaultStage = .storeInstallation
    for _ in 0..<160 {
      if runtime.extensions(forProfileID: profile.uuidString).contains(where: {
        $0["id"] as? String == extensionID
      }) {
        vaultStageResults["store-consent"] = true
        return
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    throw BitwardenProbeFailure("Store extension was not registered.")
  }

  private func openVaultPopup() async throws -> String? {
    let ownerProfile = store.session.selectedSpace.profileID
    guard let initialTab = store.session.selectedSpace.selectedTabID
    else { return nil }
    var sourceTab = initialTab
    var welcomeNavigations = 0
    for _ in 0..<100 {
      engine.refreshExtensions()
      if engine.extensionPanel == nil { engine.executeExtension(extensionID) }
      if case .popup(let popup) = engine.extensionPanel {
        attachHiddenPopup(popup.id)
        guard let selected = store.session.selectedSpace.selectedTab else { return nil }
        if selected.id != sourceTab {
          guard store.session.selectedSpace.profileID == ownerProfile,
            welcomeNavigations < 2, selected.url.host() == "bitwarden.com",
            selected.url.path().hasPrefix("/browser-start"),
            runtime.view(forExtensionPopupID: popup.id) == nil
          else {
            throw BitwardenProbeFailure("Bitwarden welcome navigation left its owned profile.")
          }
          welcomeNavigations += 1
          sourceTab = selected.id
          engine.extensionPanel = nil
          try await Task.sleep(for: .milliseconds(100))
          continue
        }
        return popup.id
      }
      guard store.session.selectedSpace.profileID == ownerProfile,
        let selected = store.session.selectedSpace.selectedTab
      else { return nil }
      if selected.id != sourceTab {
        guard welcomeNavigations < 2, selected.url.host() == "bitwarden.com",
          selected.url.path().hasPrefix("/browser-start")
        else { throw BitwardenProbeFailure("Bitwarden welcome navigation left its owned profile.") }
        welcomeNavigations += 1
        sourceTab = selected.id
        engine.executeExtension(extensionID)
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    return nil
  }

  private func writeVaultAccountReport(label: String, signedOut: Bool, authenticated: Bool)
    throws
  {
    let base = root.appending(path: "bitwarden-vault")
    try FileManager.default.createDirectory(
      at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
    let directory = base.appending(path: label)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let report: [String: Any] = [
      "phase": phase, "accountLabel": label, "signedOutLoginUI": signedOut,
      "authenticated": authenticated, "controlOnly": true,
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    try data.write(to: directory.appending(path: "signed-out.json"), options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: directory.appending(path: "signed-out.json").path)
  }

  private func writeVaultResult(passed: Bool) throws {
    let labels = [
      "store-consent", "onboarding-control", "signed-out-alpha", "signed-out-beta",
      "self-hosted-server-alpha", "self-hosted-server-beta", "account-alpha-login",
      "account-beta-login", "initial-locked-alpha", "initial-locked-beta",
      "initial-unlock-alpha", "initial-unlock-beta", "initial-restart-locked-alpha",
      "initial-restart-locked-beta",
      "account-alpha-identity-matches", "account-beta-identity-matches",
      "account-alpha-cross-profile-mismatch", "account-beta-cross-profile-mismatch",
      "separate-profile-isolation", "shared-alpha-space-retains-profile", "restart-locked-alpha",
      "restart-locked-beta", "restart-unlock-alpha", "restart-unlock-beta",
      "first-click-compatibility",
    ]
    let stages = labels.map { ["label": $0, "passed": vaultStageResults[$0] ?? false] }
    let report: [String: Any] = [
      "phase": phase, "passed": passed, "controlOnly": true,
      "firstClickAcceptancePassed": false, "accountCount": 2, "stages": stages,
      "lastStage": vaultStage.rawValue,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: root.appending(path: "\(phase)-bitwarden-vault.json"), options: .atomic)
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

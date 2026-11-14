// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Observation
import SwiftUI

enum ProfileAccountSignInAccessibility {
  static var loadingLabel: String { SettingsL10n.string("Loading sign-in…") }
}

/// Signs a profile in to, or out of, a provider account in a window that uses that
/// profile's own engine storage. The window keeps no tabs once it closes.
@MainActor
final class ProfileAccountSignIn {
  enum Purpose { case signIn, signOut }

  let store: BrowserStore
  let engine: BrowserEngine
  let window: NSWindow
  let provider: AccountProvider
  let profileID: UUID
  private let profile: BrowserProfile
  private let events: BrowserRuntimeEvents
  private let visible: Bool
  private var popups: [String: SignInPopup] = [:]
  private let purpose: Purpose
  private let presentation = ProfileAccountSignInPresentation()
  private var finished = false
  private var watcher: Task<Void, Never>?
  var onFinished: ((ConnectedAccount?) -> Void)?

  init(
    events: BrowserRuntimeEvents, profile: BrowserProfile, provider: AccountProvider,
    purpose: Purpose, visible: Bool = true, option: AccountSignInOption? = nil
  ) throws {
    self.provider = provider
    self.purpose = purpose
    self.profile = profile
    self.events = events
    self.visible = visible
    profileID = profile.id
    let entry = option.flatMap { $0.provider == provider ? $0 : nil } ?? .standard(for: provider)
    let url = purpose == .signIn ? entry.signInURL : provider.signOutURL
    let space = BrowserSpace(
      profileID: profile.id, name: provider.title, symbol: "person.crop.circle", tint: .ocean,
      tabs: [BrowserTab(url: url)])
    store = BrowserStore(
      session: try BrowserSession(profiles: [profile], spaces: [space], selectedSpaceID: space.id))
    let id = UUID().uuidString
    try events.runtime.createWindowID(id)
    let creationGuard = NativeWindowCreationGuard { _ = events.runtime.closeWindowID(id) }
    defer { creationGuard.closeIfUnowned() }
    guard let window = events.runtime.window(forID: id),
      let content = events.runtime.hostView(forWindowID: id)
    else { throw WorkspaceError.invalidState }
    self.window = window
    configureSignInWindowForFullScreenHost(window)
    engine = try BrowserEngine(events: events, windowID: id, store: store)
    let hosting = NSHostingView(
      rootView: ProfileAccountSignInView(
        store: store, engine: engine, presentation: presentation,
        title: SettingsL10n.format(
          "Sign in to %@ for %@", .string(provider.title), .string(profile.name))
      ) { [weak self] in self?.cancel() }.settingsLocalization())
    hosting.frame = content.bounds
    hosting.autoresizingMask = [.width, .height]
    content.addSubview(hosting)
    window.title = SettingsL10n.format("%@ sign-in", .string(provider.title))
    window.setContentSize(NSSize(width: 520, height: 680))
    window.minSize = NSSize(width: 420, height: 520)
    engine.onClosed = { [weak self] _ in self?.finish(nil) }
    engine.reconcile()
    if purpose == .signIn && visible {
      window.center()
      window.makeKeyAndOrderFront(nil)
    }
    watcher = Task { [weak self] in await self?.watch() }
    creationGuard.transferToOwner()
  }

  /// Polls the page until the provider reports a finished sign-in, or until sign-out has loaded.
  private func watch() async {
    for poll in 0..<(purpose == .signIn ? 1_200 : 30) {
      do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
      guard !finished else { return }
      if purpose == .signOut {
        // Sign-out pages clear cookies while they load and then redirect; give them two seconds.
        let loaded = !engine.pages.isEmpty && engine.pages.values.allSatisfy { !$0.loading }
        if loaded && poll >= 4 { return finish(nil) }
        continue
      }
      for surface in [(store, engine)] + popups.values.map({ ($0.store, $0.engine) }) {
        for tab in surface.0.session.selectedSpace.tabs {
          guard !finished, !Task.isCancelled else { return }
          switch provider {
          case .google: await watchGoogle(tab, engine: surface.1)
          case .microsoft, .apple: await watchAccount(tab)
          }
        }
      }
    }
    finish(nil)
  }

  private func watchGoogle(_ tab: BrowserTab, engine: BrowserEngine) async {
    let url = tab.url
    if provider.isSignedInPage(url), !presentation.readsAccountList {
      presentation.readsAccountList = true
      if !engine.navigateCurrentPage(to: GoogleAccountList.url) {
        presentation.readsAccountList = false
      }
    } else if url.host() == GoogleAccountList.url.host(),
      url.path() == GoogleAccountList.url.path(),
      let body = await evaluate(GoogleAccountList.readScript, tab: tab.id),
      let accounts = GoogleAccountList.accounts(fromBody: body)
    {
      if var account = accounts.first {
        if account.photoData == nil {
          account.photoData = await readPhoto(account.photoURL, tab: tab.id)
        }
        guard !finished else { return }
        return finish(account)
      }
      // Google left sign-in without a session; return to sign-in instead of showing the raw list.
      if engine.navigateCurrentPage(to: provider.signInURL) {
        presentation.readsAccountList = false
      }
    }
  }

  /// Federated redirects and MFA stay untouched. Only signed-in provider account UI can
  /// establish the primary account; a typed address or a login hint cannot complete the flow.
  private func watchAccount(_ tab: BrowserTab) async {
    if provider.isSignedInPage(tab.url) {
      if let body = await evaluate(SessionAccountPage.readScript(for: provider), tab: tab.id),
        var account = SessionAccountPage.account(from: body, provider: provider)
      {
        if account.photoData == nil {
          account.photoData = await readPhoto(
            SessionAccountPage.photoSource(from: body, provider: provider), tab: tab.id)
        }
        guard !finished else { return }
        finish(account)
      }
      return
    }
  }

  private func evaluate(_ script: String, tab: UUID) async -> String? {
    let json = await AccountSignInEvaluation.evaluate { completion in
      engine.runtime.evaluate(inTabID: tab.uuidString, script: script) { completion($0) }
    }
    guard let data = json?.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(String.self, from: data)
  }

  /// Reads a bounded thumbnail using the profile's browser session, never the system cookie jar.
  private func readPhoto(_ url: URL?, tab: UUID) async -> Data? {
    guard let url, let script = SessionAccountPage.photoScript(url: url) else { return nil }
    for _ in 0..<12 {
      guard !finished, !Task.isCancelled else { return nil }
      if let result = await evaluate(script, tab: tab) {
        if result == "unavailable" { return nil }
        if let data = SessionAccountPage.photoData(from: result) { return data }
      }
      do { try await Task.sleep(for: .milliseconds(100)) } catch { return nil }
    }
    return nil
  }

  /// Chromium asks before it attaches the popup tab. A disposable host keeps opener, cookies,
  /// MFA and postMessage intact without adding an unfinished profile to the saved catalog.
  func requestedWindow(type: String) -> String? {
    guard !finished, purpose == .signIn, ["normal", "popup"].contains(type) else { return nil }
    do {
      let popup = try SignInPopup(
        events: events, profile: profile, presentation: presentation,
        cancel: { [weak self] in
          self?.cancel()
        })
      let id = popup.engine.windowID
      popups[id] = popup
      popup.engine.onClosed = { [weak self] _ in self?.popups[id] = nil }
      DispatchQueue.main.async { [weak self, weak popup] in
        guard self?.popups[id] === popup else { return }
        popup?.engine.reconcile()
      }
      return id
    } catch { return nil }
  }

  func ownsWindow(_ id: String) -> Bool {
    !finished && (id == engine.windowID || popups[id] != nil)
  }

  var windowIDs: Set<String> {
    finished ? [] : Set(popups.keys).union([engine.windowID])
  }

  func showWindow(_ id: String, active: Bool) {
    guard visible, !finished, let window = popups[id]?.window else { return }
    if active { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
  }

  /// Abandons the flow, as the window's own Cancel button does.
  func cancel() { finish(nil) }

  private func finish(_ account: ConnectedAccount?) {
    guard !finished else { return }
    finished = true
    watcher?.cancel()
    for id in Array(popups.keys) { engine.runtime.closeWindowID(id) }
    popups.removeAll()
    engine.runtime.closeWindowID(engine.windowID)
    onFinished?(account)
  }
}

enum AccountSignInEvaluation {
  typealias Completion = @Sendable (String?) -> Void
  typealias Start = @MainActor (@escaping Completion) -> Void

  @MainActor
  static func evaluate(start: Start) async -> String? {
    let completion = AccountSignInContinuation()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        completion.install(continuation)
        guard !Task.isCancelled else {
          completion.resume(nil)
          return
        }
        start { completion.resume($0) }
      }
    } onCancel: {
      completion.resume(nil)
    }
  }
}

private final class AccountSignInContinuation: @unchecked Sendable {
  private enum State {
    case waiting
    case installed(CheckedContinuation<String?, Never>)
    case finished(String?)
  }

  private let lock = NSLock()
  private var state = State.waiting

  func install(_ continuation: CheckedContinuation<String?, Never>) {
    lock.lock()
    let result: State
    switch state {
    case .waiting:
      state = .installed(continuation)
      lock.unlock()
      return
    case .installed:
      lock.unlock()
      preconditionFailure("An account sign-in continuation can only be installed once.")
    case .finished(let value):
      result = .finished(value)
    }
    lock.unlock()
    if case .finished(let value) = result { continuation.resume(returning: value) }
  }

  func resume(_ value: String?) {
    lock.lock()
    let continuation: CheckedContinuation<String?, Never>?
    switch state {
    case .waiting:
      state = .finished(value)
      continuation = nil
    case .installed(let installed):
      state = .finished(value)
      continuation = installed
    case .finished:
      continuation = nil
    }
    lock.unlock()
    continuation?.resume(returning: value)
  }
}

@MainActor
private final class SignInPopup {
  let store: BrowserStore
  let engine: BrowserEngine
  let window: NSWindow

  init(
    events: BrowserRuntimeEvents, profile: BrowserProfile,
    presentation: ProfileAccountSignInPresentation, cancel: @escaping () -> Void
  ) throws {
    let space = BrowserSpace(
      profileID: profile.id, name: profile.name, symbol: "person", tint: .ocean)
    store = BrowserStore(
      session: try BrowserSession(
        profiles: [profile], spaces: [space], selectedSpaceID: space.id))
    let id = UUID().uuidString
    try events.runtime.createWindowID(id)
    let creationGuard = NativeWindowCreationGuard { _ = events.runtime.closeWindowID(id) }
    defer { creationGuard.closeIfUnowned() }
    guard let window = events.runtime.window(forID: id),
      let content = events.runtime.hostView(forWindowID: id)
    else { throw WorkspaceError.invalidState }
    self.window = window
    configureSignInWindowForFullScreenHost(window)
    engine = try BrowserEngine(events: events, windowID: id, store: store)
    let hosting = NSHostingView(
      rootView: ProfileAccountSignInView(
        store: store, engine: engine, presentation: presentation, title: profile.name,
        cancel: cancel
      ).settingsLocalization())
    hosting.frame = content.bounds
    hosting.autoresizingMask = [.width, .height]
    content.addSubview(hosting)
    window.setContentSize(NSSize(width: 520, height: 680))
    creationGuard.transferToOwner()
  }
}

/// Keep auth windows in the active full-screen Space instead of creating a new Space.
@MainActor
private func configureSignInWindowForFullScreenHost(_ window: NSWindow) {
  window.collectionBehavior = [.fullScreenAuxiliary]
}

/// Google answers a plain visit to its account list with a 400 page, so the page stays covered
/// from that request until the window closes or sign-in starts over.
@MainActor @Observable
private final class ProfileAccountSignInPresentation {
  var readsAccountList = false
}

private struct ProfileAccountSignInView: View {
  let store: BrowserStore
  let engine: BrowserEngine
  let presentation: ProfileAccountSignInPresentation
  let title: String
  let cancel: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Image(systemName: "lock.fill").foregroundStyle(.secondary)
        Text(store.session.selectedPage?.tab.url.host() ?? "").lineLimit(1)
        Spacer()
        Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        Button(SettingsL10n.string("Cancel"), role: .cancel, action: cancel)
          .keyboardShortcut(.cancelAction)
      }
      .padding(10)
      .background(Color(nsColor: .windowBackgroundColor))
      Divider()
      ZStack {
        Color(nsColor: .textBackgroundColor)
        if presentation.readsAccountList {
          ProgressView(SettingsL10n.string("Finishing sign-in…"))
        } else if let id = store.session.selectedSpace.selectedTabID, engine.pages[id] != nil {
          ChromiumPage(engine: engine, tabID: id)
        } else {
          ProgressView().accessibilityLabel(ProfileAccountSignInAccessibility.loadingLabel)
        }
      }
    }
  }
}

import AppKit
import BrowserCore
import SwiftUI

/// Signs a profile in to, or out of, a Google or Microsoft account in a window that uses that
/// profile's own engine storage. The window keeps no tabs once it closes.
@MainActor
final class ProfileAccountSignIn {
  enum Purpose { case signIn, signOut }

  let store: BrowserStore
  let engine: BrowserEngine
  let window: NSWindow
  let provider: AccountProvider
  private let purpose: Purpose
  private var capturedEmail: String?
  private var requestedAccountList = false
  private var finished = false
  private var watcher: Task<Void, Never>?
  var onFinished: ((ConnectedAccount?) -> Void)?

  init(
    events: BrowserRuntimeEvents, profile: BrowserProfile, provider: AccountProvider,
    purpose: Purpose
  ) throws {
    self.provider = provider
    self.purpose = purpose
    let url = purpose == .signIn ? provider.signInURL : provider.signOutURL
    let space = BrowserSpace(
      profileID: profile.id, name: provider.title, symbol: "person.crop.circle", tint: .ocean,
      tabs: [BrowserTab(url: url)])
    store = BrowserStore(
      session: try BrowserSession(profiles: [profile], spaces: [space], selectedSpaceID: space.id))
    let id = UUID().uuidString
    try events.runtime.createWindowID(id)
    guard let window = events.runtime.window(forID: id),
      let content = events.runtime.hostView(forWindowID: id)
    else { throw WorkspaceError.invalidState }
    self.window = window
    engine = try BrowserEngine(events: events, windowID: id, store: store)
    let hosting = NSHostingView(
      rootView: ProfileAccountSignInView(
        store: store, engine: engine, title: "Sign in to \(provider.title) for \(profile.name)"
      ) { [weak self] in self?.finish(nil) })
    hosting.frame = content.bounds
    hosting.autoresizingMask = [.width, .height]
    content.addSubview(hosting)
    window.title = "\(provider.title) sign-in"
    window.setContentSize(NSSize(width: 520, height: 680))
    window.minSize = NSSize(width: 420, height: 520)
    engine.onClosed = { [weak self] _ in self?.finish(nil) }
    engine.reconcile()
    if purpose == .signIn {
      window.center()
      window.makeKeyAndOrderFront(nil)
    }
    watcher = Task { [weak self] in await self?.watch() }
  }

  /// Polls the page until the provider reports a finished sign-in, or until sign-out has loaded.
  private func watch() async {
    for poll in 0..<(purpose == .signIn ? 1_200 : 30) {
      do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
      guard !finished, let url = store.session.selectedPage?.tab.url else { continue }
      if purpose == .signOut {
        // Sign-out pages clear cookies while they load and then redirect; give them two seconds.
        let loaded = !engine.pages.isEmpty && engine.pages.values.allSatisfy { !$0.loading }
        if loaded && poll >= 4 { return finish(nil) }
        continue
      }
      switch provider {
      case .google: await watchGoogle(url)
      case .microsoft: await watchMicrosoft(url)
      }
    }
    finish(nil)
  }

  private func watchGoogle(_ url: URL) async {
    if provider.isSignedInPage(url), !requestedAccountList {
      requestedAccountList = engine.navigateCurrentPage(to: GoogleAccountList.url)
    } else if url.host() == GoogleAccountList.url.host(),
      url.path() == GoogleAccountList.url.path(),
      let body = await evaluate("document.body ? document.body.innerText : ''"),
      let accounts = GoogleAccountList.accounts(fromBody: body)
    {
      if let account = accounts.first { return finish(account) }
      // Google left sign-in without a session; return to sign-in instead of showing the raw list.
      if engine.navigateCurrentPage(to: provider.signInURL) { requestedAccountList = false }
    }
  }

  private func watchMicrosoft(_ url: URL) async {
    if MicrosoftSignInPage.isSignInPage(url),
      let email = await evaluate(MicrosoftSignInPage.emailScript), email.contains("@")
    {
      capturedEmail = email
    } else if provider.isSignedInPage(url), let email = capturedEmail {
      finish(ConnectedAccount(provider: .microsoft, email: email))
    }
  }

  private func evaluate(_ script: String) async -> String? {
    guard let tab = store.session.selectedPage?.tab.id else { return nil }
    let json: String? = await withCheckedContinuation { continuation in
      engine.runtime.evaluate(inTabID: tab.uuidString, script: script) {
        continuation.resume(returning: $0)
      }
    }
    guard let data = json?.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(String.self, from: data)
  }

  private func finish(_ account: ConnectedAccount?) {
    guard !finished else { return }
    finished = true
    watcher?.cancel()
    onFinished?(account)
    engine.runtime.closeWindowID(engine.windowID)
  }
}

private struct ProfileAccountSignInView: View {
  let store: BrowserStore
  let engine: BrowserEngine
  let title: String
  let cancel: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Image(systemName: "lock.fill").foregroundStyle(.secondary)
        Text(store.session.selectedPage?.tab.url.host() ?? "").lineLimit(1)
        Spacer()
        Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        Button("Cancel", action: cancel)
      }
      .padding(10)
      .background(Color(nsColor: .windowBackgroundColor))
      Divider()
      ZStack {
        Color(nsColor: .textBackgroundColor)
        if let id = store.session.selectedSpace.selectedTabID, engine.pages[id] != nil {
          ChromiumPage(engine: engine, tabID: id)
        } else {
          ProgressView()
        }
      }
    }
  }
}

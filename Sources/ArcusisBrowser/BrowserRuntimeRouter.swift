import AppKit

/// One window's subscriptions. The dispatcher keeps this object weakly.
@MainActor
final class BrowserRuntimeClient {
  let windowID: String
  let profileIDs: () -> Set<String>
  var onWindowClosed: ((Bool) -> Void)?
  var onNotice: ((String) -> Void)?
  var onInstallRequest: (([String: Any]) -> Void)?
  var onExtensionPopup: (([String: Any]) -> Void)?
  var onExtensionPopupClosed: ((String) -> Void)?
  var onExtensionPopupSize: ((String, NSSize) -> Void)?
  var onWebsiteMediaRequest: (([String: Any]) -> Void)?
  var onWebsiteMediaDismissed: ((String) -> Void)?
  var onMediaAccess: ((String, [String: NSNumber]) -> Void)?
  var onFindResult: ((String, String, Int32, Int32, Bool) -> Void)?
  var onDownloadChanged: ((String, [String: Any]) -> Void)?
  var onDownloadRemoved: ((String, String) -> Void)?
  var onDownloadsRestored: ((String, [[String: Any]]) -> Void)?
  var onLibraryChanged: ((String, String) -> Void)?
  var onLibraryError: ((String, String, String) -> Void)?
  var onTabChanged: ((String, String, String, Bool, Bool, Bool) -> Void)?
  var onTabClosed: ((String) -> Void)?
  var onRendererGone: ((String, String, String, Int32) -> Void)?
  var onDocumentCommitted: ((String, String) -> Void)?
  var onNewTab: ((String, String, String, String?, Bool) -> Void)?

  init(windowID: String, profileIDs: @escaping () -> Set<String>) {
    self.windowID = windowID
    self.profileIDs = profileIDs
  }
}

enum BrowserRoutingError: Error, LocalizedError {
  case duplicateWindow

  var errorDescription: String? { "This native window already has an application client." }
}

/// Retains ownership until close delivery, after Chromium has removed its tab mapping.
@MainActor
final class BrowserRuntimeRouter {
  enum Context: CaseIterable { case popup, installation, media }

  private struct Subscription {
    weak var client: BrowserRuntimeClient?
  }
  private var subscriptions: [String: Subscription] = [:]
  private var retiredWindows: Set<String> = []
  private var tabOwners: [String: String] = [:]
  private var contexts: [Context: [String: String]] = [:]

  func register(_ client: BrowserRuntimeClient) throws {
    guard subscriptions[client.windowID] == nil, !retiredWindows.contains(client.windowID) else {
      throw BrowserRoutingError.duplicateWindow
    }
    subscriptions[client.windowID] = Subscription(client: client)
  }

  var clients: [BrowserRuntimeClient] { subscriptions.values.compactMap(\.client) }

  func clients(forProfile id: String) -> [BrowserRuntimeClient] {
    clients.filter { $0.profileIDs().contains(id) }
  }

  @discardableResult
  func bindTab(_ id: String, windowID: String) -> Bool {
    guard subscriptions[windowID]?.client != nil,
      tabOwners[id] == nil || tabOwners[id] == windowID
    else { return false }
    tabOwners[id] = windowID
    return true
  }

  func forgetTab(_ id: String, windowID: String) {
    guard tabOwners[id] == windowID else { return }
    tabOwners[id] = nil
  }

  func client(forTab id: String, nativeWindowID: String?) -> BrowserRuntimeClient? {
    guard let owner = tabOwners[id], owner == nativeWindowID else { return nil }
    return subscriptions[owner]?.client
  }

  func tabClosed(_ id: String) {
    guard let owner = tabOwners.removeValue(forKey: id) else { return }
    subscriptions[owner]?.client?.onTabClosed?(id)
  }

  /// A context can only be introduced by a bound tab in the declared window.
  func claim(_ context: Context, id: String, payload: [String: Any]) -> BrowserRuntimeClient? {
    guard !id.isEmpty, let window = payload["windowID"] as? String,
      let tab = payload["tabID"] as? String, tabOwners[tab] == window,
      let client = subscriptions[window]?.client,
      contexts[context]?[id] == nil || contexts[context]?[id] == window
    else { return nil }
    contexts[context, default: [:]][id] = window
    return client
  }

  func client(for context: Context, id: String, removing: Bool = false) -> BrowserRuntimeClient? {
    guard let owner = contexts[context]?[id] else { return nil }
    if removing { contexts[context]?[id] = nil }
    return subscriptions[owner]?.client
  }

  func consume(_ context: Context, id: String, windowID: String) -> Bool {
    guard contexts[context]?[id] == windowID else { return false }
    contexts[context]?[id] = nil
    return true
  }

  func windowClosed(_ id: String, quitting: Bool) {
    let client = subscriptions.removeValue(forKey: id)?.client
    retiredWindows.insert(id)
    tabOwners = tabOwners.filter { $0.value != id }
    for context in Context.allCases {
      contexts[context] = contexts[context]?.filter { $0.value != id }
    }
    client?.onWindowClosed?(quitting)
  }
}

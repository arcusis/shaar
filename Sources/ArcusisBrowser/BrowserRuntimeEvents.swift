import ChromiumBridge

/// Installs the shared runtime callbacks once, before any window client is created.
@MainActor
final class BrowserRuntimeEvents {
  let runtime: ARCChromiumRuntime
  let router = BrowserRuntimeRouter()
  var onWindowClosed: ((String, Bool) -> Void)?

  init(runtime: ARCChromiumRuntime) {
    self.runtime = runtime
    runtime.onWindowClosed = { [weak self] id, quitting in
      self?.router.windowClosed(id, quitting: quitting)
      self?.onWindowClosed?(id, quitting)
    }
    runtime.onNotice = { [weak self] message in
      for client in self?.router.clients ?? [] { client.onNotice?(message) }
    }
    runtime.onTabChanged = { [weak self] id, address, title, loading, back, forward in
      self?.tabClient(id)?.onTabChanged?(id, address, title, loading, back, forward)
    }
    runtime.onTabClosed = { [weak self] id in self?.router.tabClosed(id) }
    runtime.onRendererGone = { [weak self] id, profile, status, code in
      self?.tabClient(id)?.onRendererGone?(id, profile, status, code)
    }
    runtime.onDocumentCommitted = { [weak self] id, profile in
      self?.tabClient(id)?.onDocumentCommitted?(id, profile)
    }
    runtime.onNewTab = { [weak self] id, profile, address, opener, foreground in
      guard let self, let window = self.runtime.windowID(forTabID: id),
        self.router.bindTab(id, windowID: window), let client = self.tabClient(id)
      else {
        self?.runtime.discardTabID(id)
        return
      }
      client.onNewTab?(id, profile, address, opener, foreground)
    }
    runtime.onFindResult = { [weak self] id, token, count, active, final in
      self?.tabClient(id)?.onFindResult?(id, token, count, active, final)
    }
    runtime.onMediaAccess = { [weak self] id, access in
      self?.tabClient(id)?.onMediaAccess?(id, access)
    }
    runtime.onExtensionPopup = { [weak self] payload in
      guard let self else { return }
      guard let id = payload["id"] as? String,
        let client = self.router.claim(.popup, id: id, payload: payload),
        let receive = client.onExtensionPopup
      else {
        if let window = payload["windowID"] as? String {
          self.runtime.closeExtensionPopup(forWindowID: window)
        }
        return
      }
      receive(payload)
    }
    runtime.onExtensionPopupClosed = { [weak self] id in
      self?.router.client(for: .popup, id: id, removing: true)?.onExtensionPopupClosed?(id)
    }
    runtime.onExtensionPopupSize = { [weak self] id, size in
      self?.router.client(for: .popup, id: id)?.onExtensionPopupSize?(id, size)
    }
    runtime.onInstallRequest = { [weak self] payload in
      guard let self, let id = payload["requestId"] as? String else { return }
      guard let client = self.router.claim(.installation, id: id, payload: payload),
        let receive = client.onInstallRequest
      else {
        self.runtime.resolveInstallRequestID(id, accepted: false)
        return
      }
      receive(payload)
    }
    runtime.onWebsiteMediaRequest = { [weak self] payload in
      guard let self, let id = payload["id"] as? String else { return }
      guard let client = self.router.claim(.media, id: id, payload: payload),
        let receive = client.onWebsiteMediaRequest
      else {
        self.runtime.resolveWebsiteMediaRequestID(id, accepted: false)
        return
      }
      receive(payload)
    }
    runtime.onWebsiteMediaDismissed = { [weak self] id in
      self?.router.client(for: .media, id: id, removing: true)?.onWebsiteMediaDismissed?(id)
    }
    runtime.onDownloadChanged = { [weak self] profile, record in
      for client in self?.router.clients(forProfile: profile) ?? [] {
        client.onDownloadChanged?(profile, record)
      }
    }
    runtime.onDownloadRemoved = { [weak self] profile, id in
      for client in self?.router.clients(forProfile: profile) ?? [] {
        client.onDownloadRemoved?(profile, id)
      }
    }
    runtime.onDownloadsRestored = { [weak self] profile, rows in
      for client in self?.router.clients(forProfile: profile) ?? [] {
        client.onDownloadsRestored?(profile, rows)
      }
    }
    runtime.onLibraryChanged = { [weak self] profile, section in
      for client in self?.router.clients(forProfile: profile) ?? [] {
        client.onLibraryChanged?(profile, section)
      }
    }
    runtime.onLibraryError = { [weak self] profile, section, message in
      for client in self?.router.clients(forProfile: profile) ?? [] {
        client.onLibraryError?(profile, section, message)
      }
    }
  }

  private func tabClient(_ id: String) -> BrowserRuntimeClient? {
    router.client(forTab: id, nativeWindowID: runtime.windowID(forTabID: id))
  }

  func resolveInstall(_ id: String, windowID: String, accepted: Bool) {
    guard router.consume(.installation, id: id, windowID: windowID) else { return }
    runtime.resolveInstallRequestID(id, accepted: accepted)
  }

  func resolveMedia(_ id: String, windowID: String, accepted: Bool) {
    guard router.consume(.media, id: id, windowID: windowID) else { return }
    runtime.resolveWebsiteMediaRequestID(id, accepted: accepted)
  }

  func applyBookmarkOperation(
    _ operation: [String: Any], profileID: String, completion: @escaping @MainActor (Error?) -> Void
  ) {
    runtime.applyBookmarkOperation(operation, profileID: profileID) { [weak self] error in
      // The pinned apply endpoint does not emit bookmark events for its own writes.
      // Every window using this profile must refresh after an acknowledged mutation.
      if error == nil {
        for client in self?.router.clients(forProfile: profileID) ?? [] {
          client.onLibraryChanged?(profileID, "bookmarks")
        }
      }
      completion(error)
    }
  }

  func deleteHistoryURL(
    _ address: String, profileID: String, completion: @escaping @MainActor (Error?) -> Void
  ) {
    runtime.deleteHistoryURL(address, profileID: profileID) { [weak self] error in
      if error == nil {
        for client in self?.router.clients(forProfile: profileID) ?? [] {
          client.onLibraryChanged?(profileID, "history")
        }
      }
      completion(error)
    }
  }
}

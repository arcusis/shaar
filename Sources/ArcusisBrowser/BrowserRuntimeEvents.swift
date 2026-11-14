// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge

/// Installs the shared runtime callbacks once, before any window client is created.
@MainActor
final class BrowserRuntimeEvents {
  let runtime: ARCChromiumRuntime
  let router = BrowserRuntimeRouter()
  var onWindowClosed: ((String, Bool) -> Void)?
  var onDeviceChooserResolution: ((String, String, Int?) -> Void)?
  var onQuitRequested: (() -> Void)?
  var onQuitCancelled: (() -> Void)?
  var onWindowRequest: (@MainActor @Sendable (String, String) -> String?)? {
    didSet { runtime.onWindowRequest = onWindowRequest }
  }
  var onWindowShowRequest: (@MainActor @Sendable (String, Bool) -> Void)? {
    didSet { runtime.onWindowShowRequest = onWindowShowRequest }
  }
  var onDevToolsOpenURLRequest: (@MainActor @Sendable ([String: Any]) -> Void)? {
    didSet { runtime.onDevToolsOpenURLRequest = onDevToolsOpenURLRequest }
  }
  var onNewTabWillAdopt: ((String, String, String?) -> Void)?

  init(runtime: ARCChromiumRuntime) {
    self.runtime = runtime
    runtime.onQuitRequested = { [weak self] in self?.prepareForQuit() }
    runtime.onQuitCancelled = { [weak self] in
      self?.router.cancelQuit()
      self?.onQuitCancelled?()
    }
    runtime.onWindowClosed = { [weak self] id, quitting in
      self?.windowClosed(id, quitting: quitting)
    }
    runtime.onNotice = { [weak self] message in
      for client in self?.router.clients ?? [] { client.onNotice?(message) }
    }
    runtime.onTabChanged = { [weak self] id, address, title, loading, back, forward in
      guard self?.router.isQuitting == false else { return }
      self?.tabClient(id)?.onTabChanged?(id, address, title, loading, back, forward)
    }
    runtime.onTabClosed = { [weak self] id, windowID in
      self?.router.tabClosed(id, windowID: windowID)
    }
    runtime.onTabActivated = { [weak self] id, profile in
      guard self?.router.isQuitting == false else { return }
      self?.tabClient(id)?.onTabActivated?(id, profile)
    }
    runtime.onRendererGone = { [weak self] id, profile, status, code in
      self?.tabClient(id)?.onRendererGone?(id, profile, status, code)
    }
    runtime.onDocumentCommitted = { [weak self] id, profile in
      self?.tabClient(id)?.onDocumentCommitted?(id, profile)
    }
    runtime.onTabLifecycle = { [weak self] id, state, audible, capturing in
      self?.tabClient(id)?.onTabLifecycle?(id, state, audible, capturing)
    }
    runtime.onNewTab = { [weak self] id, profile, address, opener, foreground in
      guard self?.router.isQuitting == false else { return }
      guard let self, let window = self.runtime.windowID(forTabID: id),
        self.router.bindTab(id, windowID: window), let client = self.tabClient(id)
      else {
        self?.runtime.discardTabID(id)
        return
      }
      self.onNewTabWillAdopt?(id, profile, opener)
      client.onNewTab?(id, profile, address, opener, foreground)
    }
    runtime.onFindResult = { [weak self] id, token, count, active, final in
      self?.tabClient(id)?.onFindResult?(id, token, count, active, final)
    }
    runtime.onMediaAccess = { [weak self] id, access in
      self?.tabClient(id)?.onMediaAccess?(id, access)
    }
    runtime.onAgentBridgeStatus = { [weak self] id, profile, status in
      self?.tabClient(id)?.onAgentBridgeStatus?(id, profile, status)
    }
    runtime.onDevToolsPanelEvent = { [weak self] id, profile, window, payload, sequence in
      guard let self, self.runtime.windowID(forTabID: id) == window,
        let client = self.tabClient(id), client.windowID == window
      else { return }
      client.onDevToolsPanelEvent?(id, profile, payload, sequence)
    }
    runtime.onMediaSessionChanged = { [weak self] id, state in
      self?.tabClient(id)?.onMediaSessionChanged?(id, state)
    }
    runtime.onPictureInPictureChanged = { [weak self] id, active in
      self?.tabClient(id)?.onPictureInPictureChanged?(id, active)
    }
    runtime.onTabActivationRequest = { [weak self] id, reason in
      self?.tabClient(id)?.onTabActivationRequest?(id, reason)
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
    runtime.onDesktopCaptureRequest = { [weak self] payload in
      guard let self, let id = payload["id"] as? String else { return }
      guard let client = self.router.claim(.desktopCapture, id: id, payload: payload) else {
        self.runtime.resolveDesktopCaptureRequestID(id, sourceID: nil)
        return
      }
      guard let receive = client.onDesktopCaptureRequest else {
        _ = self.router.consume(.desktopCapture, id: id, windowID: client.windowID)
        self.runtime.resolveDesktopCaptureRequestID(id, sourceID: nil)
        return
      }
      receive(payload)
    }
    runtime.onDesktopCaptureDismissed = { [weak self] id in
      guard let client = self?.router.client(for: .desktopCapture, id: id, removing: true) else {
        return
      }
      client.onDesktopCaptureDismissed?(id)
    }
    runtime.onWebShareRequest = { [weak self] payload in
      guard let self, let id = payload["id"] as? String else { return }
      guard let client = self.router.claim(.webShare, id: id, payload: payload) else {
        self.runtime.resolveWebShareRequestID(id, outcome: WebShareOutcome.cancelled.rawValue)
        return
      }
      guard let receive = client.onWebShareRequest else {
        _ = self.router.consume(.webShare, id: id, windowID: client.windowID)
        self.runtime.resolveWebShareRequestID(id, outcome: WebShareOutcome.cancelled.rawValue)
        return
      }
      receive(payload)
    }
    runtime.onPrintRequest = { [weak self] payload in
      guard let self, let id = payload["id"] as? String else { return }
      guard let client = self.router.claim(.print, id: id, payload: payload) else {
        self.runtime.resolvePrintRequestID(id, accepted: false)
        return
      }
      guard let receive = client.onPrintRequest else {
        _ = self.router.consume(.print, id: id, windowID: client.windowID)
        self.runtime.resolvePrintRequestID(id, accepted: false)
        return
      }
      receive(payload)
    }
    runtime.onJavaScriptDialogRequest = { [weak self] payload in
      guard let self, let id = payload["id"] as? String,
        let client = self.router.claim(.javascriptDialog, id: id, payload: payload),
        let receive = client.onJavaScriptDialogRequest
      else {
        if let id = payload["id"] as? String {
          self?.runtime.resolveJavaScriptDialogRequestID(id, accepted: false, input: nil)
        }
        return
      }
      receive(payload)
    }
    runtime.onJavaScriptDialogDismissed = { [weak self] id in
      guard let client = self?.router.client(for: .javascriptDialog, id: id, removing: true)
      else { return }
      client.onJavaScriptDialogDismissed?(id)
    }
    runtime.onExternalAppRequest = { [weak self] payload in
      guard let self, let id = payload["id"] as? String else { return }
      guard !self.router.owns(.externalApp, id: id) else { return }
      guard let client = self.router.claim(.externalApp, id: id, payload: payload) else {
        self.runtime.resolveExternalAppRequestID(id, accepted: false)
        return
      }
      guard let receive = client.onExternalAppRequest else {
        _ = self.router.consume(.externalApp, id: id, windowID: client.windowID)
        self.runtime.resolveExternalAppRequestID(id, accepted: false)
        return
      }
      receive(payload)
    }
    runtime.onExternalAppDismissed = { [weak self] id in
      self?.router.client(for: .externalApp, id: id, removing: true)?.onExternalAppDismissed?(id)
    }
    runtime.onDeviceChooserEvent = { [weak self] payload in
      guard let self, let id = payload["id"] as? String, let kind = payload["kind"] as? String
      else { return }
      if kind == "deviceChooserRequested" {
        guard let client = self.router.claim(.deviceChooser, id: id, payload: payload),
          let receive = client.onDeviceChooserEvent
        else {
          self.runtime.resolveDeviceChooserRequestID(id, index: nil)
          return
        }
        receive(payload)
        return
      }
      if kind == "deviceChooserDismissed" {
        self.router.client(for: .deviceChooser, id: id, removing: true)?.onDeviceChooserEvent?(
          payload)
        return
      }
      guard kind == "deviceChooserUpdated" else { return }
      guard let client = self.router.client(for: .deviceChooser, id: id),
        let receive = client.onDeviceChooserEvent
      else {
        if let owner = self.router.client(for: .deviceChooser, id: id)?.windowID {
          _ = self.router.consume(.deviceChooser, id: id, windowID: owner)
        }
        self.runtime.resolveDeviceChooserRequestID(id, index: nil)
        return
      }
      receive(payload)
    }
    runtime.onHTTPAuthRequest = { [weak self] payload in
      guard let self, let id = payload["id"] as? String else { return }
      guard let client = self.router.claim(.httpAuth, id: id, payload: payload) else {
        if let tabID = payload["tabID"] as? String {
          self.runtime.resolveHTTPAuthRequestID(id, tabID: tabID, username: nil, password: nil)
        }
        return
      }
      guard let receive = client.onHTTPAuthRequest else {
        _ = self.router.consume(.httpAuth, id: id, windowID: client.windowID)
        if let tabID = payload["tabID"] as? String {
          self.runtime.resolveHTTPAuthRequestID(id, tabID: tabID, username: nil, password: nil)
        }
        return
      }
      receive(payload)
    }
    runtime.onHTTPAuthDismissed = { [weak self] id in
      self?.router.client(for: .httpAuth, id: id, removing: true)?.onHTTPAuthDismissed?(id)
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

  func windowClosed(_ id: String, quitting: Bool) {
    let quitting = quitting || router.isQuitting || runtime.isQuitting
    guard router.windowClosed(id, quitting: quitting) else { return }
    onWindowClosed?(id, quitting)
  }

  func quit() {
    prepareForQuit()
    runtime.quit()
  }

  private func prepareForQuit() {
    guard !router.isQuitting else { return }
    router.prepareForQuit()
    onQuitRequested?()
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

  func resolveDesktopCapture(_ id: String, windowID: String, sourceID: String?) {
    guard router.consume(.desktopCapture, id: id, windowID: windowID) else { return }
    runtime.resolveDesktopCaptureRequestID(id, sourceID: sourceID)
  }

  func resolveWebShare(_ id: String, windowID: String, outcome: WebShareOutcome) {
    guard router.consume(.webShare, id: id, windowID: windowID) else { return }
    runtime.resolveWebShareRequestID(id, outcome: outcome.rawValue)
  }

  func resolvePrint(_ id: String, windowID: String, accepted: Bool) {
    guard router.consume(.print, id: id, windowID: windowID) else { return }
    runtime.resolvePrintRequestID(id, accepted: accepted)
  }

  func resolveJavaScriptDialog(_ id: String, accepted: Bool, input: String?) {
    guard router.client(for: .javascriptDialog, id: id, removing: true) != nil else { return }
    runtime.resolveJavaScriptDialogRequestID(id, accepted: accepted, input: input)
  }

  func resolveExternalApp(_ id: String, windowID: String, accepted: Bool) {
    guard router.consume(.externalApp, id: id, windowID: windowID) else { return }
    runtime.resolveExternalAppRequestID(id, accepted: accepted)
  }

  func resolveDeviceChooser(_ id: String, windowID: String, index: Int?) {
    guard router.consume(.deviceChooser, id: id, windowID: windowID) else { return }
    if let onDeviceChooserResolution {
      onDeviceChooserResolution(id, windowID, index)
      return
    }
    runtime.resolveDeviceChooserRequestID(id, index: index.map(NSNumber.init(value:)))
  }

  func resolveHTTPAuth(_ request: HTTPAuthRequest, username: String?, password: String?) {
    guard router.consume(.httpAuth, id: request.id, windowID: request.windowID) else { return }
    runtime.resolveHTTPAuthRequestID(request.id, tabID: request.tabID.uuidString,
                                     username: username, password: password)
  }

  func rejectHTTPAuth(_ id: String, tabID: String, windowID: String) {
    guard router.consume(.httpAuth, id: id, windowID: windowID) else { return }
    runtime.resolveHTTPAuthRequestID(id, tabID: tabID, username: nil, password: nil)
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

// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Foundation

struct DevToolsOpenURLRequest {
  let windowID: String
  let tabID: UUID
  let profileID: UUID
  let contextID: String?
  let url: URL

  init?(_ payload: [String: Any]) {
    guard payload["schemaVersion"] as? Int == 1,
      payload["kind"] as? String == "openURLRequested",
      payload["disposition"] as? String == "newForegroundTab",
      let windowID = payload["sourceWindowID"] as? String,
      UUID(uuidString: windowID) != nil,
      let tab = payload["sourceTabID"] as? String, let tabID = UUID(uuidString: tab),
      let profile = payload["profileID"] as? String, let profileID = UUID(uuidString: profile),
      let address = payload["url"] as? String, address.utf8.count <= 8192,
      let url = URL(string: address),
      NavigationInput.isWebURL(url) || NavigationInput.isDevToolsFrontendURL(url)
    else { return nil }
    let contextID = payload["contextID"] as? String
    if let contextID, UUID(uuidString: contextID) == nil { return nil }
    self.windowID = windowID
    self.tabID = tabID
    self.profileID = profileID
    self.contextID = contextID
    self.url = url
  }
}

extension BrowserEngine {
  @discardableResult
  func showDeveloperTools(for target: SiteControlTarget) -> Bool {
    guard siteControlTarget == target else { return false }
    let viewportsTransport: any ShaarViewportsTransport
    if let shaar = runtime as? ARCShaarRuntime {
      viewportsTransport = ShaarViewportsNativeTransport(
        requester: ShaarViewportRuntimeRequester(
          runtime: shaar, windowID: windowID, contextID: nil))
    } else {
      viewportsTransport = ShaarViewportsPendingTransport()
    }
    let shell =
      shaarDevTools[target.tabID]
      ?? ShaarDevToolsModel(
        target: target, viewportsTransport: viewportsTransport,
        localTransports: [ShaarNextMCPConsoleTransport(), ShaarSpotlightConsoleTransport()])
    let inspector = inspectors[target.tabID] ?? InspectorModel(target: target, engine: self)
    shaarDevTools[target.tabID] = shell
    inspectors[target.tabID] = inspector
    shell.updateTarget(target)
    shell.open(inspector: inspector)
    return true
  }

  func toggleDeveloperTools() {
    guard let target = siteControlTarget else { return }
    if let shell = shaarDevTools[target.tabID], shell.isOpen {
      shell.close()
    } else {
      _ = showDeveloperTools(for: target)
    }
  }

  @discardableResult
  func openChromiumDeveloperTools(for tabID: UUID) -> Bool {
    guard !isClosed, liveTabs.contains(tabID),
      runtime.windowID(forTabID: tabID.uuidString) == windowID
    else { return false }
    let shown = runtime.showDevTools(forTabID: tabID.uuidString)
    if let target = siteControlTarget, target.tabID == tabID {
      developerModels[tabID]?.update(target: target)
    }
    return shown
  }

  func toggleChromiumDeveloperTools() {
    guard let target = siteControlTarget else { return }
    let identity = target.tabID.uuidString
    runtime.toggleDevTools(forTabID: identity) { [weak self] error in
      if let error { self?.reportNotice(error.localizedDescription) }
      self?.developerModels[target.tabID]?.update(target: target)
    }
  }
}

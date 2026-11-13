// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

extension BrowserEngine {
  func receiveDeviceChooser(_ payload: [String: Any]) {
    guard let id = payload["id"] as? String, let kind = payload["kind"] as? String else { return }
    guard payload["windowID"] as? String == windowID, let store else {
      if kind == "deviceChooserRequested" {
        events.resolveDeviceChooser(id, windowID: windowID, optionID: nil)
      }
      return
    }
    switch kind {
    case "deviceChooserDismissed":
      store.dismissDeviceChooserFromEngine(id)
    case "deviceChooserUpdated":
      guard let request = deviceChooserRequest(payload, store: store),
        store.updateDeviceChooser(request)
      else {
        store.dismissDeviceChooserFromEngine(id)
        events.resolveDeviceChooser(id, windowID: windowID, optionID: nil)
        return
      }
    case "deviceChooserRequested":
      extensionPanel = nil
      guard let request = deviceChooserRequest(payload, store: store),
        store.requestDeviceChooser(request)
      else {
        events.resolveDeviceChooser(id, windowID: windowID, optionID: nil)
        return
      }
    default:
      events.resolveDeviceChooser(id, windowID: windowID, optionID: nil)
    }
  }

  func settleDeviceChooser(_ request: DeviceChooserRequest, optionID: String?) {
    events.resolveDeviceChooser(request.id, windowID: windowID, optionID: optionID)
  }

  private func deviceChooserRequest(
    _ payload: [String: Any], store: BrowserStore
  ) -> DeviceChooserRequest? {
    guard let tabID = (payload["tabID"] as? String).flatMap(UUID.init(uuidString:)),
      let tab = store.session.selectedSpace.selectedTab, tab.id == tabID
    else { return nil }
    return DeviceChooserIntake.request(
      tabID: tabID, profileID: store.session.profileID(forTabID: tabID), pageURL: tab.url,
      payload: payload)
  }
}

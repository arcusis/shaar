// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import Foundation

extension BrowserEngine {
  func deviceChooserDisplayTitle(_ title: String) -> String {
    DeviceChooserSignal.parse(title: title)?.previousTitle ?? title
  }

  func noteDeviceChooserTitle(tabID: UUID, url: URL, title: String) {
    guard let store else { return }
    let blocked = ShaarBluetoothIOIsBlocked()
    guard let request = DeviceChooserIntake.request(
      tabID: tabID, profileID: store.session.profileID(forTabID: tabID), pageURL: url,
      title: title, bluetoothBlocked: blocked)
    else { return }
    if store.deviceChooserRequests.contains(where: { $0.id == request.id }) { return }
    guard store.requestDeviceChooser(request) else {
      settleDeviceChooser(request, optionIndex: nil)
      return
    }
  }

  func settleDeviceChooser(_ request: DeviceChooserRequest, optionIndex: Int?) {
    let action = optionIndex == nil ? "reject" : "use-native"
    let script = DeviceChooserScript.settle(signalID: request.signalID, action: action)
    evaluateDeviceChooser(tabID: request.tabID, script: script, attempt: 0)
  }

  func installDeviceChooserHook(tabID: UUID, url: URL) {
    guard url.scheme == "http" || url.scheme == "https", url.host != nil else { return }
    scheduleDeviceChooserInstall(tabID: tabID, attempt: 0)
  }

  private func scheduleDeviceChooserInstall(tabID: UUID, attempt: Int) {
    guard attempt < 8, !isClosed else { return }
    let script = DeviceChooserScript.install(bluetoothBlocked: ShaarBluetoothIOIsBlocked())
    runtime.evaluate(inTabID: tabID.uuidString, script: script) { [weak self] result in
      Task { @MainActor in
        guard let self, !Self.chooserJSONFlag(result, name: "installed") else { return }
        try? await Task.sleep(for: .milliseconds(250))
        self.scheduleDeviceChooserInstall(tabID: tabID, attempt: attempt + 1)
      }
    }
  }

  private func evaluateDeviceChooser(tabID: UUID, script: String, attempt: Int) {
    guard attempt < 8, !isClosed else { return }
    runtime.evaluate(inTabID: tabID.uuidString, script: script) { [weak self] result in
      Task { @MainActor in
        guard let self, !Self.chooserJSONFlag(result, name: "settled") else { return }
        try? await Task.sleep(for: .milliseconds(250))
        self.evaluateDeviceChooser(tabID: tabID, script: script, attempt: attempt + 1)
      }
    }
  }

  private nonisolated static func chooserJSONFlag(_ result: String?, name: String) -> Bool {
    guard let result else { return false }
    return result.contains("\"\(name)\":true") || result.contains("\"\(name)\": true")
  }
}

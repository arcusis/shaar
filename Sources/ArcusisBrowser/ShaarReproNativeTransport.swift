// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import Foundation

@MainActor final class ShaarReproNativeTransport: ShaarReproTransport {
  let requiresMaskedFrames = true
  private let runtime: ARCShaarRuntime
  private let panel: ShaarDevToolsNativeTransport
  private weak var inspector: InspectorModel?

  init(
    runtime: ARCShaarRuntime, panel: ShaarDevToolsNativeTransport,
    inspector: InspectorModel
  ) {
    self.runtime = runtime
    self.panel = panel
    self.inspector = inspector
  }

  var available: Bool { panel.recordingAvailable && inspector?.isOpen == true }

  func capture(for target: SiteControlTarget, seconds: Int) async throws -> ShaarReproCapture {
    guard available, let inspector, inspector.target == target,
      (1...ShaarReproBundle.seconds).contains(seconds)
    else { throw ShaarReproNativeError.unavailable }
    let dom = try await ShaarReproDOMSnapshot.capture(inspector, target: target)
    guard available, inspector.target == target,
      let userAgent = try await inspector.evaluate("navigator.userAgent") as? String,
      userAgent.utf8.count <= 1024,
      let viewport = runtime.view(forTabID: target.tabID.uuidString),
      viewport.bounds.width > 0, viewport.bounds.height > 0
    else { throw ShaarReproNativeError.unavailable }
    let environment = ShaarReproEnvironment(
      url: target.url.absoluteString,
      shaarVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
      engineVersion: runtime.chromiumVersion,
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      userAgent: userAgent,
      viewportWidth: Int(viewport.bounds.width),
      viewportHeight: Int(viewport.bounds.height))
    return ShaarReproCapture(
      videoMP4: Data(), durationSeconds: seconds, dom: dom,
      console: [], network: [], environment: environment)
  }
}

private enum ShaarReproNativeError: Error { case unavailable }

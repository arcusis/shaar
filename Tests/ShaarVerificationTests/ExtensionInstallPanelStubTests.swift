// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import ObjectiveC.runtime
import Testing

@testable import ShaarVerification

@Suite(.serialized) @MainActor
struct ExtensionInstallPanelStubTests {
  @Test func folderChooserReturnsTheFixtureWithoutADialog() {
    let selector = #selector(NSSavePanel.runModal)
    let inherited = class_getInstanceMethod(NSOpenPanel.self, selector)
    let before = inherited.map(method_getImplementation)
    defer { ExtensionInstallPanelStub.restore() }
    #expect(ExtensionInstallPanelStub.install())
    defer { ExtensionInstallPanelStub.directory = nil }

    let replacement = class_getInstanceMethod(
      NSOpenPanel.self, #selector(NSOpenPanel.shaarProbeRunModal))
    let replaced = inherited.map(method_getImplementation)
    let stub = replacement.map(method_getImplementation)
    guard let before, let replaced, let stub, replaced != before, replaced == stub else {
      Issue.record("Load unpacked still uses the system folder chooser.")
      return
    }

    let directory = URL(filePath: "/tmp/shaar-extension-panel-stub", directoryHint: .isDirectory)
    ExtensionInstallPanelStub.directory = directory
    let panel = NSOpenPanel()
    #expect(panel.runModal() == .OK)
    #expect(panel.url == directory)
  }
}

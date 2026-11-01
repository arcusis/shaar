// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Test func pickerRejectsDimensionsThatCannotBeRenderedAsIntegers() {
  let base: [String: Any] = [
    "css": "button", "xpath": "//button", "locator": ["code": "page.locator(\"button\")"],
    "height": 10.0,
  ]
  for width in [Double.infinity, Double.nan, -1, Double.greatestFiniteMagnitude] {
    var value = base
    value["width"] = width
    #expect(PickedElement(value) == nil)
  }
}

@Test func pickerKeepsUnexposedComponentInformationAbsent() {
  let value: [String: Any] = [
    "css": "span", "xpath": "//span", "locator": ["code": "page.locator(\"span\")"], "width": 20.0,
    "height": 10.0,
  ]
  let element = PickedElement(value)
  #expect(element?.component == nil && element?.source == nil)
}

@MainActor @Test func siteControlsBoundTallContentWithoutOrderingWindow() async throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let host = NSHostingView(
    rootView: SiteControlsScrollContainer { Text("Tall controls").frame(height: 2000) })
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 320, height: 720), styleMask: .borderless,
    backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = host
  defer {
    window.contentView = nil
    window.close()
  }
  host.layoutSubtreeIfNeeded()
  try await Task.sleep(for: .milliseconds(100))
  #expect(!window.isVisible && host.fittingSize.height <= 740 && host.fittingSize.height > 0)
}

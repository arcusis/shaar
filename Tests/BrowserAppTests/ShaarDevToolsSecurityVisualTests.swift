// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarDevToolsSecurityVisualTests: XCTestCase {
  func testSecurityPanelRendersOffscreenInBothAppearances() throws {
    guard ProcessInfo.processInfo.environment["SHAAR_DEVTOOLS_SECURITY_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen security capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1310")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let presented = PresentationCounter()
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      try render(
        summary: httpSummary, name: "after-http-\(suffix)", appearance: appearance, scheme: scheme,
        root: root, presented: presented)
      try render(
        summary: secureSummary, name: "after-security-\(suffix)", appearance: appearance,
        scheme: scheme, root: root, presented: presented)
    }
    XCTAssertEqual(presented.count, 0)
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  private func render(
    summary: ShaarDevToolsSecuritySummary, name: String, appearance: NSAppearance.Name,
    scheme: ColorScheme, root: URL, presented: PresentationCounter
  ) throws {
    let defaults = UserDefaults(suiteName: "ShaarDevToolsSecurityCapture.\(UUID().uuidString)")!
    let target = SiteControlTarget(tabID: UUID(), profileID: UUID(), url: summaryURL(summary))
    let inspector = InspectorModel(target: target, engine: nil)
    let shell = ShaarDevToolsModel(target: target, layoutDefaults: defaults)
    shell.securitySummary = summary
    shell.presentCertificate = { presented.count += 1 }
    shell.section = .security
    shell.open(inspector: inspector)
    let panel = ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {})
      .frame(width: 850, height: 620)
      .environment(\.colorScheme, scheme)
    try VisualCapture.renderOffscreen(
      panel, size: NSSize(width: 850, height: 620), appearance: appearance,
      to: root.appending(path: "\(name).png"))
    shell.close()
  }

  private var httpSummary: ShaarDevToolsSecuritySummary {
    ShaarDevToolsSecuritySummary.make(
      url: URL(string: "http://localhost:3000/")!, engineLevel: "insecure", certificate: nil)
  }

  private var secureSummary: ShaarDevToolsSecuritySummary {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let identity = ShaarCertificateIdentity(
      subject: "Common Name=localhost, Organization=Shaar Test",
      issuer: "Common Name=Shaar Test CA, Organization=Shaar Test",
      notBefore: formatter.date(from: "2026-11-07T03:15:36Z")!,
      notAfter: formatter.date(from: "2027-11-12T03:15:36Z")!)
    return ShaarDevToolsSecuritySummary.make(
      url: URL(string: "https://localhost/")!, engineLevel: "secure", certificate: identity)
  }

  private func summaryURL(_ summary: ShaarDevToolsSecuritySummary) -> URL {
    if summary.connection == .http { return URL(string: "http://localhost:3000/")! }
    return URL(string: "https://localhost/")!
  }
}

private final class PresentationCounter {
  var count = 0
}

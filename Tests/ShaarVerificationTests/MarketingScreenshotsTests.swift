// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ShaarVerification

@MainActor
@Suite struct MarketingScreenshotsTests {
  @Test func publicWorkspaceKeepsGitHubInBackgroundAndUsesRequestedSpaces() throws {
    let session = try MarketingScreenshots.seed()
    #expect(session.profiles.map(\.name) == ["Work", "Personal"])
    #expect(session.spaces.map(\.name) == ["Work", "Hasbara", "Freight"])
    #expect(session.selectedSpaceID == session.spaces[0].id)
    #expect(
      session.spaces.map { $0.selectedTab?.url.host() }
        == ["arcusis.com", "hasbara.co.il", "freightfte.com"])
    #expect(session.spaces[0].tint == .forest)
    #expect(session.spaces[1].tint == .ocean)
    #expect(session.spaces[2].customRGB == SpaceRGBColor(hex: "#DCA34B"))
    let tabs = session.spaces.flatMap(\.tabs)
    #expect(tabs.count == 4)
    #expect(
      tabs.allSatisfy { $0.url.scheme == "https" && $0.url.user == nil && $0.url.password == nil })
    #expect(tabs.filter { $0.url.absoluteString == "https://github.com/arcusis/shaar" }.count == 1)
    #expect(session.spaces.allSatisfy { $0.selectedTab?.url.host() != "github.com" })
  }

  @Test func missingDataDirectoryIsRejectedBeforeStartingRuntime() {
    #expect(MarketingScreenshots.run(arguments: ["--marketing-screenshots"]) == 1)
  }

  @Test func existingChromiumDataIsRejectedWithoutTouchingIt() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "arcusis-engine-probe-marketing-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appending(path: ".arcusis-probe")
    try Data("arcusis-engine-probe-v1\n".utf8).write(to: marker)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    let chromium = root.appending(path: "Chromium")
    try FileManager.default.createDirectory(at: chromium, withIntermediateDirectories: false)
    let sentinel = chromium.appending(path: "existing-data")
    let original = Data("preserve existing browser data".utf8)
    try original.write(to: sentinel)
    #expect(
      MarketingScreenshots.run(arguments: ["--probe-data-dir", root.path]) == 1)
    #expect(try Data(contentsOf: sentinel) == original)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == [
        ".arcusis-probe", "Chromium",
      ])
  }
}

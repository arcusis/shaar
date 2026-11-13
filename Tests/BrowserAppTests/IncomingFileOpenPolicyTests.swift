// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import Testing

@testable import ArcusisBrowser

struct IncomingFileOpenPolicyTests {
  @Test func readableFileSymlinkOpensItsCanonicalTarget() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appending(path: "document.html")
    let alias = root.appending(path: "alias.html")
    let missing = root.appending(path: "missing.html")
    let brokenAlias = root.appending(path: "broken.html")
    try Data("<p>ok</p>".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
    try FileManager.default.createSymbolicLink(at: brokenAlias, withDestinationURL: missing)

    #expect(
      IncomingFileOpenPolicy.readableFileURL(alias)
        == target.resolvingSymlinksInPath().standardizedFileURL)
    #expect(IncomingFileOpenPolicy.readableFileURL(brokenAlias) == nil)
  }
}

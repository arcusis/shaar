// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Testing
import UniformTypeIdentifiers

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserExternalDropTests {
  @Test func dropAcceptsOnlyWebURLsAndReadableRegularFiles() throws {
    let webURL = try #require(URL(string: "https://drop.example/page"))
    #expect(BrowserExternalDrop.openableURL(from: webURL as NSURL) == webURL)
    #expect(
      BrowserExternalDrop.openableURL(
        from: NSURL(string: "https://user:secret@drop.example/")!) == nil)

    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "dropped.html")
    try Data("<h1>Page</h1>".utf8).write(to: file)
    #expect(
      BrowserExternalDrop.openableURL(from: file as NSURL)
        == file.resolvingSymlinksInPath().standardizedFileURL)
    #expect(
      BrowserExternalDrop.openableURL(from: root as NSURL) == nil)
    #expect(
      BrowserExternalDrop.openableURL(from: URL(string: "javascript:alert(1)")! as NSURL) == nil)
  }

  @Test func urlItemProviderDeliversAValidatedWebAddress() async throws {
    let expected = try #require(URL(string: "https://drop.example/from-provider"))
    let provider = NSItemProvider()
    provider.registerDataRepresentation(
      forTypeIdentifier: UTType.url.identifier, visibility: .all
    ) { completion in
      completion(Data(expected.absoluteString.utf8), nil)
      return nil
    }

    let delivered: URL? = await withCheckedContinuation { continuation in
      let accepted = BrowserExternalDrop.receive([provider]) { continuation.resume(returning: $0) }
      if !accepted { continuation.resume(returning: nil) }
    }
    #expect(delivered == expected)
  }
}

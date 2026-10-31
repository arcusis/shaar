// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

struct IncomingURLPolicyTests {
  @Test func acceptsOrdinaryWebLinks() {
    #expect(IncomingURLPolicy.url(from: "https://example.test/path?q=1")?.host() == "example.test")
    #expect(IncomingURLPolicy.url(from: "http://example.test")?.scheme == "http")
  }

  @Test func rejectsLinksLongerThanThirtyTwoKilobytes() {
    let prefix = "https://example.test/?q="
    let atLimit =
      prefix + String(repeating: "a", count: IncomingURLPolicy.maximumLength - prefix.count)
    #expect(atLimit.utf8.count == 32 * 1024)
    #expect(IncomingURLPolicy.url(from: atLimit) != nil)
    #expect(IncomingURLPolicy.url(from: atLimit + "a") == nil)
    let multibyte = prefix + String(repeating: "é", count: IncomingURLPolicy.maximumLength / 2)
    #expect(IncomingURLPolicy.url(from: multibyte) == nil)
  }

  @Test func rejectsCredentialsInTheAuthority() {
    for text in [
      "https://user:pass@example.test/", "https://user@example.test/",
      "https://:secret@example.test/", "https://bank.example@attacker.test/login",
      "https://user%40corp:pass@example.test/",
    ] {
      #expect(IncomingURLPolicy.url(from: text) == nil, "\(text)")
    }
    #expect(IncomingURLPolicy.url(from: "https://example.test/user@mail") != nil)
  }

  @Test func rejectsNonWebSchemes() {
    for text in ["file:///etc/passwd", "javascript:alert(1)", "shaar://settings", "https://"] {
      #expect(IncomingURLPolicy.url(from: text) == nil, "\(text)")
    }
  }
}

struct StartupFailureMessageTests {
  private static let path = "/Users/someone/Library/Application Support/Shaar/workspace.lock"

  @Test func mapsKnownFailuresToStableSentences() {
    #expect(
      StartupFailureMessage.text(for: WorkspaceLockError.inUse).hasPrefix(
        "Browser startup failed: Another \(ProductIdentity.name) process is using this workspace."))
    #expect(
      StartupFailureMessage.text(for: WorkspaceError.invalidState).contains(
        "The saved workspace could not be opened."))
    #expect(
      StartupFailureMessage.text(for: POSIXError(.EACCES)).contains(
        "The browser data folder is not accessible."))
    let engine = NSError(
      domain: "com.arcusis.browser.chromium", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Framework missing at \(Self.path)"])
    #expect(
      StartupFailureMessage.text(for: engine)
        == "Browser startup failed: The browser engine could not be loaded. [com.arcusis.browser.chromium 1]"
    )
  }

  @Test func neverIncludesPathsFromTheErrorDescription() {
    let fileError = CocoaError(
      .fileWriteNoPermission, userInfo: [NSFilePathErrorKey: Self.path])
    let unknown = NSError(
      domain: "Example", code: 7, userInfo: [NSLocalizedDescriptionKey: "Failed at \(Self.path)"])
    #expect(fileError.localizedDescription.contains("workspace.lock"))
    for error in [fileError as Error, unknown] {
      let text = StartupFailureMessage.text(for: error)
      #expect(!text.contains("/Users"), "\(text)")
      #expect(!text.contains("workspace.lock"), "\(text)")
    }
    #expect(
      StartupFailureMessage.text(for: unknown)
        == "Browser startup failed: An unexpected error occurred. [Example 7]")
    #expect(
      StartupFailureMessage.text(for: fileError).contains(
        "The browser data folder is not accessible."))
  }
}

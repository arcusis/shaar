// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@Test func extensionMetadataRejectsInvalidIDsAndUnboundedConsent() throws {
  #expect(
    BrowserExtension(id: String(repeating: "z", count: 32), name: "Example", version: "1") == nil)
  #expect(
    BrowserExtension(id: String(repeating: "a", count: 31), name: "Example", version: "1") == nil)
  #expect(BrowserExtension(id: String(repeating: "a", count: 32), name: "  ", version: "1") == nil)
  #expect(ExtensionInstallKind(rawValue: "external") == nil)
  #expect(ExtensionInstallKind(rawValue: "other") == nil)
  let browserExtension = try #require(
    BrowserExtension(id: String(repeating: "a", count: 32), name: "Example", version: "1"))
  let oversized = ExtensionInstallRequest(
    id: "install1", profileID: UUID(), tabID: UUID(),
    sourceURL: URL(string: "https://example.com")!,
    browserExtension: browserExtension, kind: .install,
    permissions: [String(repeating: "x", count: 8193)])
  #expect(oversized == nil)
  let unsafe = ExtensionInstallRequest(
    id: "install1", profileID: UUID(), tabID: UUID(),
    sourceURL: URL(string: "javascript:alert(1)")!,
    browserExtension: browserExtension, kind: .install, permissions: [])
  #expect(unsafe == nil)
}

@Test func installKindsMapEngineValuesToConsentActions() {
  #expect(ExtensionInstallKind(rawValue: "re-enable") == .reenable)
  #expect(ExtensionInstallKind.install.actionTitle == "Add extension")
  #expect(ExtensionInstallKind.permissions.actionTitle == "Allow permissions")
  #expect(ExtensionInstallKind.reenable.actionTitle == "Enable extension")
  #expect(ExtensionInstallKind.repair.actionTitle == "Repair extension")
}

@Test func extensionIDsUseChromiumAlphabetAndLength() {
  #expect(BrowserExtension.isValidID("abcdefghijklmnopabcdefghijklmnop"))
  #expect(!BrowserExtension.isValidID("ABCDEFGHIJKLMNOPABCDEFGHIJKLMNOP"))
  #expect(!BrowserExtension.isValidID(String(repeating: "q", count: 32)))
  #expect(!BrowserExtension.isValidID(String(repeating: "a", count: 33)))
  #expect(
    BrowserExtension(
      id: String(repeating: "a", count: 32), name: "Example",
      version: String(repeating: "1", count: 129)) == nil)
}

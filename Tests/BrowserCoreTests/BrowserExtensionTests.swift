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

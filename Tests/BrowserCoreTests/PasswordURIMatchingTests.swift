import Foundation
import XCTest

@testable import BrowserCore

final class PasswordURIMatchingTests: XCTestCase {
  private func bundledPolicy() throws -> PasswordPublicSuffixList {
    try XCTUnwrap(PasswordPublicSuffixList.bundled(), "Resource failure: \(bundledFailure())")
  }

  private func bundledFailure() -> String {
    switch PasswordPublicSuffixList.bundledResult() {
    case .success: return "none"
    case .failure(let reason): return String(describing: reason)
    }
  }
  private func context(_ origin: String, _ document: String? = nil) -> PasswordFillContext {
    let trustedOrigin = PasswordFillOrigin(origin)!
    return PasswordFillContext(
      requestID: UUID(),
      binding: PasswordFillBinding(windowID: UUID(), profileID: UUID(), tabID: UUID()),
      origin: trustedOrigin,
      documentURL: document.flatMap { PasswordFillDocumentURL($0, origin: trustedOrigin) }
    )
  }

  func testBundledDomainPolicyBoundaries() throws {
    let policy = PasswordURIMatching(suffixes: try bundledPolicy())
    let rows: [(String, String, PasswordURIMatchStrategy?, PasswordURIMatchResult)] = [
      ("example.com", "https://login.example.com", nil, .match),
      ("http://example.com:8080", "https://login.example.com:444", .domain, .match),
      ("example.com", "https://example.com.evil.org", .domain, .noMatch),
      ("example.co.uk", "https://shop.example.co.uk", .domain, .match),
      ("co.uk", "https://example.co.uk", .domain, .noMatch),
      ("a.github.io", "https://b.github.io", .domain, .noMatch),
      ("a.github.io", "https://x.a.github.io", .domain, .match),
      ("a.foo.ck", "https://b.foo.ck", .domain, .noMatch),
      ("www.ck", "https://x.www.ck", .domain, .match),
      ("example.unknownsuffix", "https://a.example.unknownsuffix", .domain, .match),
      ("localhost", "https://localhost", .domain, .match),
      ("localhost", "https://foo.localhost", .domain, .noMatch),
      ("foo.localhost", "https://bar.foo.localhost", .domain, .match),
      ("http://localdevice", "https://localdevice", .domain, .noMatch),
      ("http://127.0.0.1", "https://127.0.0.1", .domain, .match),
      ("http://[2001:db8::1]", "https://[2001:db8::1]", .domain, .match),
      ("https://测试.com", "https://login.xn--0zwm56d.com", .domain, .match),
      ("xn--0zwm56d.com", "https://login.xn--0zwm56d.com", .domain, .match),
      ("example.com.", "https://login.example.com", .domain, .match),
      ("google.com", "https://script.google.com", .domain, .noMatch),
      ("google.com", "https://script.google.com:444", .domain, .match),
    ]
    for (saved, origin, mode, expected) in rows {
      XCTAssertEqual(
        policy.match(savedURI: saved, strategy: mode, context: context(origin)), expected,
        "saved=\(saved), origin=\(origin)")
    }
  }

  func testHostPortsDefaultAndRawURLModes() throws {
    let policy = PasswordURIMatching(suffixes: try bundledPolicy())
    let rows:
      [(
        String, PasswordURIMatchStrategy?, PasswordURIMatchStrategy?, String, String?,
        PasswordURIMatchResult
      )] = [
        ("localhost", .host, nil, "https://localhost", nil, .noMatch),
        ("http://localhost", .host, nil, "https://localhost", nil, .match),
        ("http://example.com", .host, nil, "https://example.com", nil, .match),
        ("https://EXAMPLE.com:443", .host, nil, "https://example.com", nil, .match),
        ("http://example.com:80", .host, nil, "https://example.com", nil, .match),
        ("https://example.com:4000", .host, nil, "https://example.com:4000", nil, .match),
        ("https://example.com", .host, nil, "https://example.com:4000", nil, .noMatch),
        ("https://example.com", nil, .host, "https://sub.example.com", nil, .noMatch),
        ("https://example.com", nil, .never, "https://example.com", nil, .noMatch),
        (
          "https://example.com/path?x=1#f", .exact, nil, "https://example.com",
          "https://example.com/path?x=1#f", .match
        ),
        (
          "https://example.com/path?x=1", .exact, nil, "https://example.com",
          "https://example.com/path?x=1#f", .noMatch
        ),
        ("https://example.com/path", .exact, nil, "https://example.com", nil, .noMatch),
        (
          "https://example.com/path/", .startsWith, nil, "https://example.com",
          "https://example.com/path/a", .match
        ),
        (
          "https://example.com/path/", .startsWith, nil, "https://example.com",
          "https://example.com/path", .noMatch
        ),
        (
          "https://example.com", .startsWith, nil, "https://example.com.evil.org",
          "https://example.com.evil.org/", .match
        ),
        (
          "HTTPS://example.com/path", .exact, nil, "https://example.com",
          "https://example.com/path", .noMatch
        ),
        (".*", .regularExpression, nil, "https://example.com", nil, .unsupportedRegularExpression),
        ("https://example.com", .never, nil, "https://example.com", nil, .noMatch),
      ]
    for (saved, mode, fallback, origin, doc, expected) in rows {
      XCTAssertEqual(
        policy.match(
          savedURI: saved, strategy: mode, defaultStrategy: fallback,
          context: context(origin, doc)), expected, "saved=\(saved), origin=\(origin)")
    }
  }

  func testIDNAHostNormalization() {
    XCTAssertEqual(normalizedDNSHost("测试.com"), "xn--0zwm56d.com")
    XCTAssertEqual(normalizedDNSHost("xn--0zwm56d.com"), "xn--0zwm56d.com")
    XCTAssertEqual(normalizedDNSHost("рф"), "xn--p1ai")
  }

  func testMalformedSavedURIsAndMismatchedDocumentFailClosed() throws {
    let policy = PasswordURIMatching(suffixes: try bundledPolicy())
    for saved in [
      "", "https://user@example.com", "ftp://example.com", "https://example.com:99999",
      "https://example.com/%zz", "https://example.com:0", "https://example.com:-1",
      "https://example.com:abc", "https://example.com@evil.com",
      "https://example.com%2eevil.com",
      "https://example.com\\@evil.com", "https://exa mple.com", "http://127.1",
      String(repeating: "a", count: 8193),
    ] {
      XCTAssertEqual(
        policy.match(savedURI: saved, context: context("https://example.com")), .noMatch)
    }
    let origin = PasswordFillOrigin("https://example.com")!
    let other = PasswordFillOrigin("https://other.com")!
    let mismatched = PasswordFillContext(
      requestID: UUID(),
      binding: PasswordFillBinding(windowID: UUID(), profileID: UUID(), tabID: UUID()),
      origin: origin, documentURL: PasswordFillDocumentURL("https://other.com/", origin: other))
    XCTAssertEqual(policy.match(savedURI: "example.com", context: mismatched), .noMatch)
  }

  func testMalformedAndIncompleteSuffixResourcesFailClosed() {
    let valid = """
      // ===BEGIN ICANN DOMAINS===
      com
      *.ck
      !www.ck
      // ===END ICANN DOMAINS===
      // ===BEGIN PRIVATE DOMAINS===
      github.io
      // ===END PRIVATE DOMAINS===
      """
    XCTAssertNotNil(PasswordPublicSuffixList(contents: valid))
    for malformed in [
      "", "com", valid.replacingOccurrences(of: "// ===END PRIVATE DOMAINS===", with: ""),
      valid.replacingOccurrences(of: "github.io", with: "foo/bar"),
      valid.replacingOccurrences(of: "*.ck", with: "*foo.ck"),
      valid + "\nrogue.example", String(repeating: "a", count: 2_000_001),
    ] {
      XCTAssertNil(PasswordPublicSuffixList(contents: malformed))
    }
  }

  func testClassicTestBundleSiblingAndPackagedAppIsolation() throws {
    let fileManager = FileManager.default
    let testBundle = Bundle(for: PasswordURIMatchingTests.self)
    let sourceRoots = [
      Bundle.main.resourceURL, testBundle.resourceURL, Bundle.main.bundleURL,
      testBundle.bundleURL.deletingLastPathComponent(),
    ].compactMap { $0 }
    let source = try XCTUnwrap(
      sourceRoots.map {
        $0.appendingPathComponent("ArcusisBrowser_BrowserCore.bundle")
      }.first { fileManager.fileExists(atPath: $0.path) })
    let fixture = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: fixture) }
    let testContainer = fixture.appendingPathComponent("Fixture.xctest")
    try fileManager.createDirectory(at: testContainer, withIntermediateDirectories: true)
    let resource = fixture.appendingPathComponent("ArcusisBrowser_BrowserCore.bundle")
    try fileManager.copyItem(at: source, to: resource)
    let roots = PasswordPublicSuffixList.resourceRoots(
      mainBundleURL: fixture.appendingPathComponent("runner"), mainResourceURL: nil,
      mainExecutableURL: fixture.appendingPathComponent("xctest"), codeResourceURL: nil,
      loadedBundleURLs: [testContainer, fixture.appendingPathComponent("Other.bundle")])
    XCTAssertNotNil(PasswordPublicSuffixList.loadBundledResource(from: roots))

    let helperRoots = PasswordPublicSuffixList.resourceRoots(
      mainBundleURL: fixture.appendingPathComponent("runner"), mainResourceURL: nil,
      mainExecutableURL: fixture.appendingPathComponent("swiftpm-testing-helper"),
      codeResourceURL: nil, loadedBundleURLs: [testContainer])
    XCTAssertNotNil(PasswordPublicSuffixList.loadBundledResource(from: helperRoots))

    let app = fixture.appendingPathComponent("Fixture.app")
    let appRoots = PasswordPublicSuffixList.resourceRoots(
      mainBundleURL: app, mainResourceURL: app.appendingPathComponent("Contents/Resources"),
      mainExecutableURL: app.appendingPathComponent("Contents/MacOS/xctest"),
      codeResourceURL: nil, loadedBundleURLs: [testContainer])
    XCTAssertNil(PasswordPublicSuffixList.loadBundledResource(from: appRoots))
    XCTAssertFalse(appRoots.contains(fixture))
    let appHelperRoots = PasswordPublicSuffixList.resourceRoots(
      mainBundleURL: app, mainResourceURL: app.appendingPathComponent("Contents/Resources"),
      mainExecutableURL: app.appendingPathComponent("Contents/MacOS/swiftpm-testing-helper"),
      codeResourceURL: nil, loadedBundleURLs: [testContainer])
    XCTAssertFalse(appHelperRoots.contains(fixture))
    XCTAssertNil(PasswordPublicSuffixList.loadBundledResource(from: appHelperRoots))
    if case .failure(.missingBundle) = PasswordPublicSuffixList.loadBundledResourceResult(
      from: appRoots)
    {
    } else {
      XCTFail("Expected missingBundle")
    }
    let otherHostRoots = PasswordPublicSuffixList.resourceRoots(
      mainBundleURL: fixture.appendingPathComponent("runner"), mainResourceURL: nil,
      mainExecutableURL: fixture.appendingPathComponent("runner"), codeResourceURL: nil,
      loadedBundleURLs: [testContainer])
    XCTAssertNil(PasswordPublicSuffixList.loadBundledResource(from: otherHostRoots))
    let similarlyNamedHostRoots = PasswordPublicSuffixList.resourceRoots(
      mainBundleURL: fixture.appendingPathComponent("runner"), mainResourceURL: nil,
      mainExecutableURL: fixture.appendingPathComponent("swiftpm-testing-helper-extra"),
      codeResourceURL: nil, loadedBundleURLs: [testContainer])
    XCTAssertNil(PasswordPublicSuffixList.loadBundledResource(from: similarlyNamedHostRoots))

    let relocatedResources = fixture.appendingPathComponent("Relocated.app/Contents/Resources")
    try fileManager.createDirectory(at: relocatedResources, withIntermediateDirectories: true)
    try fileManager.copyItem(
      at: resource,
      to: relocatedResources.appendingPathComponent("ArcusisBrowser_BrowserCore.bundle"))
    XCTAssertNotNil(PasswordPublicSuffixList.loadBundledResource(from: [relocatedResources]))

    let bundle = try XCTUnwrap(Bundle(url: resource))
    let dataURL = try XCTUnwrap(bundle.url(forResource: "public_suffix_list", withExtension: "dat"))
    let original = try Data(contentsOf: dataURL)
    try Data("tampered".utf8).write(to: dataURL)
    XCTAssertNil(PasswordPublicSuffixList.loadBundledResource(from: roots))
    if case .failure(.hashMismatch) = PasswordPublicSuffixList.loadBundledResourceResult(
      from: helperRoots + [relocatedResources])
    {
    } else {
      XCTFail("Expected the first damaged resource to fail closed")
    }
    if case .failure(.hashMismatch) = PasswordPublicSuffixList.loadBundledResourceResult(
      from: roots)
    {
    } else {
      XCTFail("Expected hashMismatch")
    }
    try Data(repeating: 0, count: 2_000_001).write(to: dataURL)
    XCTAssertNil(PasswordPublicSuffixList.loadBundledResource(from: roots))
    if case .failure(.invalidData) = PasswordPublicSuffixList.loadBundledResourceResult(from: roots)
    {
    } else {
      XCTFail("Expected invalidData")
    }
    try original.write(to: dataURL)
    XCTAssertNotNil(PasswordPublicSuffixList.loadBundledResource(from: roots))
  }
}

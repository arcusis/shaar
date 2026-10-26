import Foundation
import XCTest

@testable import BrowserCore

final class PasswordURIMatchingTests: XCTestCase {
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
    let policy = PasswordURIMatching(suffixes: try XCTUnwrap(.bundled()))
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
    let policy = PasswordURIMatching(suffixes: try XCTUnwrap(.bundled()))
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
    let policy = PasswordURIMatching(suffixes: try XCTUnwrap(.bundled()))
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
}

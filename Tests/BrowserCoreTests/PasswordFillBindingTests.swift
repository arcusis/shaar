import Foundation
import Testing

@testable import BrowserCore

@Suite @MainActor struct PasswordFillBindingTests {
  @Test func acceptsOnlyCanonicalHTTPSOrigins() {
    for value in [
      "https://example.com", "https://example.com:8443", "https://[::1]", "https://127.0.0.1",
      "https://xn--0zwm56d.com", "https://login.xn--0zwm56d.com:8443",
    ] {
      #expect(PasswordFillOrigin(value)?.value == value)
    }
    for value in [
      "http://example.com", "HTTPS://example.com", "https://EXAMPLE.com", "https://example.com/",
      "https://example.com/path", "https://user@example.com", "https://example.com?x=1",
      "https://example.com#x", "https://example.com:443", "https://example.com:0",
      "https://example.com:65536", "https://example.com.evil/path", "https://exa%6dple.com",
      "https://example.com:", "https://example.com?", "https://example.com#",
      "https://127.000.000.001", "https://0x7f000001", "https://127.0.0.1.",
      "https://[0:0:0:0:0:0:0:1]", "https://测试.com", "https://XN--0ZWM56D.com",
      "https://xn--.com", "https://xn--a.com", "https://xn--invalid-.com",
      "https://xn--0zwm56d.com:0443", "https://xn--0zwm56d.com.evil/path",
    ] {
      #expect(PasswordFillOrigin(value) == nil, "Accepted \(value)")
    }
  }

  @Test func leaseRejectsForeignExpiredAndReplayedContexts() {
    let binding = PasswordFillBinding(windowID: UUID(), profileID: UUID(), tabID: UUID())
    let context = PasswordFillContext(
      requestID: UUID(), binding: binding, origin: PasswordFillOrigin("https://example.com")!)
    let lease = PasswordFillLease(context: context, deadline: 20)
    let foreign = PasswordFillBinding(
      windowID: UUID(), profileID: binding.profileID, tabID: binding.tabID)
    let foreignResult = lease.consume(context: context, binding: foreign, now: 1)
    let expiredResult = lease.consume(context: context, binding: binding, now: 20)
    let validResult = lease.consume(context: context, binding: binding, now: 19)
    let replayResult = lease.consume(context: context, binding: binding, now: 19)
    #expect(!foreignResult)
    #expect(!expiredResult)
    #expect(validResult)
    #expect(!replayResult)
  }

  @Test func validatesExactDocumentURLAndOrigin() {
    let origin = PasswordFillOrigin("https://example.com")!
    for value in [
      "https://example.com", "https://example.com/login?next=%2Fhome#part",
      "https://example.com/?#",
    ] {
      #expect(PasswordFillDocumentURL(value, origin: origin)?.value == value)
    }
    for value in [
      "", "http://example.com/login", "https://other.example/login",
      "https://example.com.evil/login", "https://example.com:443/login",
      "https://example.com:8443/login", "https://example.com:0/login",
      "https://example.com:65536/login", "https://user@example.com/login",
      "https://user:pass@example.com/login", "https://example.com:/login",
      "https://example.com/%zz", "https://example.com/space here",
      "https://example.com/\\evil", "https://example.com/" + String(repeating: "a", count: 8192),
    ] {
      #expect(PasswordFillDocumentURL(value, origin: origin) == nil)
    }
    let idnOrigin = PasswordFillOrigin("https://xn--0zwm56d.com")!
    #expect(PasswordFillDocumentURL("https://xn--0zwm56d.com/login?q=1", origin: idnOrigin) != nil)
    #expect(PasswordFillDocumentURL("https://xn--0zwm56d.com.evil/login", origin: idnOrigin) == nil)
    let portOrigin = PasswordFillOrigin("https://example.com:8443")!
    #expect(
      PasswordFillDocumentURL("https://example.com:8443/path?q=1#x", origin: portOrigin) != nil)
    #expect(PasswordFillDocumentURL("https://example.com/path", origin: portOrigin) == nil)
  }

  @Test func leaseBindsFullURLAndSupportsAbsentURL() {
    let binding = PasswordFillBinding(windowID: UUID(), profileID: UUID(), tabID: UUID())
    let origin = PasswordFillOrigin("https://example.com")!
    let id = UUID()
    let url = PasswordFillDocumentURL("https://example.com/path?x=1#part", origin: origin)!
    let context = PasswordFillContext(
      requestID: id, binding: binding, origin: origin, documentURL: url)
    let other = PasswordFillContext(
      requestID: id, binding: binding, origin: origin,
      documentURL: PasswordFillDocumentURL("https://example.com/path?x=2#part", origin: origin)!)
    let absent = PasswordFillContext(requestID: id, binding: binding, origin: origin)
    let lease = PasswordFillLease(context: context, deadline: 20)
    #expect(!lease.consume(context: other, binding: binding, now: 1))
    #expect(!lease.consume(context: absent, binding: binding, now: 1))
    #expect(lease.consume(context: context, binding: binding, now: 1))
    #expect(!lease.consume(context: context, binding: binding, now: 1))
    let legacy = PasswordFillLease(context: absent, deadline: 20)
    #expect(legacy.consume(context: absent, binding: binding, now: 1))
    let foreignOrigin = PasswordFillOrigin("https://other.example")!
    let inconsistent = PasswordFillContext(
      requestID: id, binding: binding, origin: origin,
      documentURL: PasswordFillDocumentURL("https://other.example/", origin: foreignOrigin)!)
    let inconsistentLease = PasswordFillLease(context: inconsistent, deadline: 20)
    #expect(!inconsistentLease.consume(context: inconsistent, binding: binding, now: 1))
  }
}

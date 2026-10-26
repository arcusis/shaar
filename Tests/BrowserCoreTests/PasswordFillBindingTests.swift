import Foundation
import Testing

@testable import BrowserCore

@Suite @MainActor struct PasswordFillBindingTests {
  @Test func acceptsOnlyCanonicalHTTPSOrigins() {
    for value in [
      "https://example.com", "https://example.com:8443", "https://[::1]", "https://127.0.0.1",
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
      "https://[0:0:0:0:0:0:0:1]",
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
}

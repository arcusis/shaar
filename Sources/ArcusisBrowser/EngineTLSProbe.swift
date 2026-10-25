import ChromiumBridge
import Foundation

@MainActor
enum EngineTLSProbe {
  static func run(
    runtime: ARCChromiumRuntime, store: BrowserStore, configuration: ProbeTLSConfiguration,
    root: URL, phase: String
  ) async throws -> [String] {
    var result: [String: Any] = [
      "schema": 1, "phase": phase, "passed": false,
      "scope": "Disposable Chromium transport only. No extension or company account acceptance.",
    ]
    func write() throws {
      try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        .write(to: root.appending(path: "\(phase)-tls.json"), options: .atomic)
    }
    do {
      guard let tab = store.session.selectedSpace.selectedTabID?.uuidString else {
        throw ProbeTLSFailure()
      }
      let matched = await request(configuration.matchedURL, runtime: runtime, tab: tab)
      result["matched"] = matched ?? [:]
      guard matched?["success"] as? Bool == true, matched?["httpStatusCode"] as? Int == 200 else {
        throw ProbeTLSFailure()
      }
      let unmatched = await request(configuration.unmatchedURL, runtime: runtime, tab: tab)
      result["unmatched"] = unmatched ?? [:]
      guard unmatched?["success"] as? Bool == false, unmatched?["netError"] as? Int == -202,
        unmatched?["netErrorName"] as? String == "net::ERR_CERT_AUTHORITY_INVALID"
      else { throw ProbeTLSFailure() }
      result["passed"] = true
      try write()
      return [
        "\(phase) Chromium accepts only the configured disposable certificate key",
        "\(phase) Chromium rejects an unrelated self-signed certificate with its authority error",
      ]
    } catch {
      try? write()
      throw ProbeTLSFailure()
    }
  }

  private static func request(_ url: URL, runtime: ARCChromiumRuntime, tab: String) async
    -> [String: Any]?
  {
    let data: Data? = await withCheckedContinuation { continuation in
      runtime.probeTLSResourceURL(url, tabID: tab) { value in
        continuation.resume(
          returning: value.flatMap { try? JSONSerialization.data(withJSONObject: $0) })
      }
    }
    guard let data else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }
}

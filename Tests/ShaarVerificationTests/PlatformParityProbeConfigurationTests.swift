// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite @MainActor struct PlatformParityProbeConfigurationTests {
  @Test func httpFixtureMustBeLoopbackHttpWithAnExplicitPort() {
    let invalid: [URL?] = [
      nil,
      URL(string: "https://127.0.0.1:8080/"),
      URL(string: "http://localhost:8080/"),
      URL(string: "http://example.invalid:8080/"),
      URL(string: "http://127.0.0.1/"),
    ]
    for http in invalid {
      #expect(run(http: http, https: URL(string: "https://127.0.0.1:8443/")) == 2)
    }
  }

  @Test func httpsFixtureMustBeLoopbackHttpsWithAnExplicitPort() {
    let invalid: [URL?] = [
      nil,
      URL(string: "http://127.0.0.1:8080/"),
      URL(string: "https://localhost:8443/"),
      URL(string: "https://example.invalid:8443/"),
      URL(string: "https://127.0.0.1/"),
    ]
    for https in invalid {
      #expect(run(http: URL(string: "http://127.0.0.1:8080/"), https: https) == 2)
    }
  }

  @Test func loopbackFixturesMustUseAConnectablePort() {
    #expect(
      run(http: URL(string: "http://127.0.0.1:0/"), https: URL(string: "https://127.0.0.1:8443/"))
        == 2)
    #expect(
      run(http: URL(string: "http://127.0.0.1:8080/"), https: URL(string: "https://127.0.0.1:0/"))
        == 2)
  }

  @Test func validLoopbackFixturesPassConfigurationBeforeRuntimeInitialization() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "platform-parity-configuration-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let outputURL = root.appending(path: "parity-result.json")

    let result = PlatformParityProbe.run(
      frameworkURL: URL(filePath: "/missing/Chromium Framework.framework"),
      outputURL: outputURL,
      httpBase: URL(string: "http://127.0.0.1:8080/"),
      httpsBase: URL(string: "https://127.0.0.1:8443/"))

    #expect(result == 1)
    let data = try Data(contentsOf: outputURL)
    let report = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(report["completed"] as? Bool == false)
    #expect(report["error"] as? String != nil)
  }

  private func run(http: URL?, https: URL?) -> Int32 {
    PlatformParityProbe.run(
      frameworkURL: URL(filePath: "/missing/Chromium Framework.framework"),
      outputURL: FileManager.default.temporaryDirectory.appending(path: "parity-result.json"),
      httpBase: http, httpsBase: https)
  }
}

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

  private func run(http: URL?, https: URL?) -> Int32 {
    PlatformParityProbe.run(
      frameworkURL: URL(filePath: "/missing/Chromium Framework.framework"),
      outputURL: FileManager.default.temporaryDirectory.appending(path: "parity-result.json"),
      httpBase: http, httpsBase: https)
  }
}

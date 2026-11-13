// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct ShaarLocalConsoleHTTPTests {
  @Test func readsSuccessfulLoopbackResponses() async throws {
    let server = try LocalConsoleFixtureServer(script: "next_mcp_fixture.py")
    defer { server.stop() }
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/_next/mcp")!)
    request.httpMethod = "POST"
    request.httpBody = Data(
      #"{"jsonrpc":"2.0","id":"test","params":{"name":"get_errors"}}"#.utf8)

    let data = try await ShaarLocalConsoleHTTP.data(for: request)
    #expect(String(decoding: data, as: UTF8.self).contains("Build failed"))
  }

  @Test func rejectsNonSuccessLoopbackResponses() async throws {
    let server = try LocalConsoleFixtureServer(script: "next_mcp_fixture.py")
    defer { server.stop() }
    let request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/missing")!)

    await #expect(throws: URLError.self) {
      try await ShaarLocalConsoleHTTP.data(for: request)
    }
  }
}

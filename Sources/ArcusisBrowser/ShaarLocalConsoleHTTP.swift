// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Only literal loopback destinations are used for local developer feeds.
enum ShaarLocalConsoleHTTP {
  static func data(for request: URLRequest) async throws -> Data {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 3
    configuration.timeoutIntervalForResource = 3
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    let session = URLSession(
      configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
      data.count <= 128_000
    else { throw URLError(.badServerResponse) }
    return data
  }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

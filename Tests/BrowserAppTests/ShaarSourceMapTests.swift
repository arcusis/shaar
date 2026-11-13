// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Test func sourceMapLoadsInlineOriginalSourcesAndAssignsMimeTypes() async throws {
  let map =
    #"{"version":3,"sourceRoot":"webpack://_N_E/","sources":["./src/app.js","styles/site.css"],"sourcesContent":["const answer = 42;","body { color: red; }"]}"#
  let reference = "data:application/json;base64,\(Data(map.utf8).base64EncodedString())"
  let result = try await ShaarSourceMap.load(
    from: "//# sourceMappingURL=\(reference)",
    resourceURL: URL(string: "https://dev.example/assets/app.js")!,
    fetch: { _ in Data() })

  #expect(
    result.map(\.url) == [
      "shaar-original://dev.example/src/app.js",
      "shaar-original://dev.example/styles/site.css",
    ])
  #expect(result.map(\.mimeType) == ["text/javascript", "text/css"])
  #expect(result.map(\.content) == ["const answer = 42;", "body { color: red; }"])
}

@Test func sourceMapFetchesOnlySameOriginReferences() async throws {
  let resource = URL(string: "https://dev.example/assets/app.js")!
  let map = Data(#"{"version":3,"sources":["src/main.ts"],"sourcesContent":["export {}"]}"#.utf8)
  let sameOrigin = try await ShaarSourceMap.load(
    from: "//# sourceMappingURL=app.js.map", resourceURL: resource,
    fetch: { url in
      #expect(url.absoluteString == "https://dev.example/assets/app.js.map")
      return map
    })
  #expect(sameOrigin.map(\.content) == ["export {}"])

  let crossOrigin = try await ShaarSourceMap.load(
    from: "//# sourceMappingURL=https://other.example/app.js.map", resourceURL: resource,
    fetch: { _ in throw TestFetchError.unexpectedCall })
  #expect(crossOrigin.isEmpty)
}

private enum TestFetchError: Error { case unexpectedCall }

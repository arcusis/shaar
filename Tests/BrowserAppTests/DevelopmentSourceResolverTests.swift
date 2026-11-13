// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite struct DevelopmentSourceResolverTests {
  @Test func mapsWebpackSourcesInsideDeclaredWorkspace() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "src/app/page.tsx")
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("export default function Page() {}".utf8).write(to: file)
    let map = Data(
      #"{"version":3,"sources":["webpack://_N_E/./src/app/page.tsx","../outside.tsx"]}"#.utf8)
    let result = DevelopmentSourceResolver.locations(
      resourceURL: URL(string: "http://localhost:3000/_next/static/chunks/app.js")!,
      workspaceRoot: root.path, framework: .nextJS, sourceMap: map)
    #expect(result.map(\.path) == [file.path])
  }

  @Test func viteResourceUsesWorkspaceRootWithoutMap() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "src/main.ts")
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: file)
    let result = DevelopmentSourceResolver.locations(
      resourceURL: URL(string: "http://localhost:5173/src/main.ts?t=123")!,
      workspaceRoot: root.path, framework: .vite, sourceMap: nil)
    #expect(result.map(\.path) == [file.path])
  }

  @Test func rejectsPathsOutsideWorkspace() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let map = Data(#"{"version":3,"sources":["../../secret.txt","file:///etc/hosts"]}"#.utf8)
    let result = DevelopmentSourceResolver.locations(
      resourceURL: URL(string: "http://localhost:3000/app.js")!,
      workspaceRoot: root.path, framework: .nextJS, sourceMap: map)
    #expect(result.isEmpty)
  }

  @Test func findsSameOriginSourceMapDirective() {
    let resource = URL(string: "http://localhost:3000/app.js")!
    let map = DevelopmentSourceResolver.sourceMapURL(
      in: "console.log(1);\n//# sourceMappingURL=app.js.map", resourceURL: resource)
    #expect(map?.absoluteString == "http://localhost:3000/app.js.map")
  }

  @Test func workspaceManifestURLRejectsCredentialedOrInvalidPageAuthorities() {
    for page in [
      "https://alice:secret@localhost:3000/app.js", "http://localhost:99999/app.js",
    ] {
      #expect(DevelopmentSourceResolver.workspaceURL(for: URL(string: page)!) == nil)
    }
    #expect(
      DevelopmentSourceResolver.workspaceURL(
        for: URL(string: "http://localhost:3000/app.js")!)?.path
        == "/.well-known/appspecific/com.chrome.devtools.json")
  }
}

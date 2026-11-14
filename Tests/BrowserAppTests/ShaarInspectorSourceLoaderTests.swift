// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ArcusisBrowser

@Test @MainActor func inspectorSourceLoaderFindsResourcesInRootAndChildFrames() {
  let reply: [String: Any] = [
    "frameTree": [
      "frame": ["id": "root"],
      "resources": [["url": "https://example.com/root.js"]],
      "childFrames": [
        [
          "frame": ["id": "child"],
          "resources": [["url": "https://example.com/child.js"]],
        ]
      ],
    ]
  ]

  #expect(
    ShaarInspectorSourceLoader.frameID(for: "https://example.com/root.js", in: reply) == "root")
  #expect(
    ShaarInspectorSourceLoader.frameID(for: "https://example.com/child.js", in: reply) == "child")
  #expect(
    ShaarInspectorSourceLoader.frameID(for: "https://example.com/missing.js", in: reply) == nil)
}

@Test @MainActor func inspectorSourceLoaderHonorsFrameAndResourceSearchBounds() {
  var deep: [String: Any] = [
    "frame": ["id": "too-deep"],
    "resources": [["url": "https://example.com/deep.js"]],
  ]
  for index in 0..<8 {
    deep = ["frame": ["id": "level-\(index)"], "childFrames": [deep]]
  }
  #expect(
    ShaarInspectorSourceLoader.frameID(
      for: "https://example.com/deep.js", in: ["frameTree": deep]) == nil)

  let resources = (0..<1_025).map { ["url": "https://example.com/\($0).js"] }
  let reply: [String: Any] = [
    "frameTree": ["frame": ["id": "root"], "resources": resources]
  ]
  #expect(
    ShaarInspectorSourceLoader.frameID(for: "https://example.com/1023.js", in: reply) == "root")
  #expect(
    ShaarInspectorSourceLoader.frameID(for: "https://example.com/1024.js", in: reply) == nil)
}

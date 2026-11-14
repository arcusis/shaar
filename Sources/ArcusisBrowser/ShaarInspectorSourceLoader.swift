// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

/// Uses the tab-scoped Inspector route when the native panel reply is too large.
@MainActor enum ShaarInspectorSourceLoader {
  static let maxContentBytes = 5 * 1024 * 1024

  static func load(url: String, target: SiteControlTarget, inspector: InspectorModel) async throws
    -> (body: String, base64Encoded: Bool)
  {
    guard inspector.isOpen, inspector.target == target,
      let resourceURL = URL(string: url),
      DevelopmentSourceResolver.sameOrigin(resourceURL, target.url)
    else { throw InspectorFailure(InspectorL10n.string("This source is no longer available.")) }

    let tree = try await inspector.call("Page.getResourceTree")
    guard let frameID = frameID(for: url, in: tree) else {
      throw InspectorFailure(InspectorL10n.string("This source is no longer in the page resource tree."))
    }
    let reply = try await inspector.call(
      "Page.getResourceContent", params: ["url": url, "frameId": frameID])
    guard let content = reply["content"] as? String,
      content.utf8.count <= maxContentBytes,
      let encoded = reply["base64Encoded"] as? Bool
    else { throw InspectorFailure(InspectorL10n.string("Source content is unavailable or exceeds 5 MiB.")) }
    return (content, encoded)
  }

  static func frameID(for url: String, in reply: [String: Any]) -> String? {
    guard let root = reply["frameTree"] as? [String: Any] else { return nil }
    return frameID(for: url, in: root, depth: 0)
  }

  private static func frameID(for url: String, in tree: [String: Any], depth: Int) -> String? {
    guard depth < 8, let frame = tree["frame"] as? [String: Any],
      let id = frame["id"] as? String
    else { return nil }
    if let resources = tree["resources"] as? [[String: Any]],
      resources.prefix(1024).contains(where: { $0["url"] as? String == url })
    {
      return id
    }
    for child in (tree["childFrames"] as? [[String: Any]] ?? []).prefix(64) {
      if let id = frameID(for: url, in: child, depth: depth + 1) { return id }
    }
    return nil
  }
}

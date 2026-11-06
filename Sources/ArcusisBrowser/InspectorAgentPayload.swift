// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A small text-only handoff from the already scrubbed Inspector context.
enum InspectorAgentPayload {
  static func markdown(_ context: InspectorAIFormatter.Context, locator: String) -> String {
    guard context.valid else { return "" }
    typealias Format = InspectorAIFormatter
    var lines = ["## Element", "Page: \(Format.url(context.url))"]
    let chain = context.components.prefix(12).filter(Format.readableComponent)
    if !chain.isEmpty {
      lines.append(
        "Component: " + chain.map { Format.inline($0, limit: 120) }.joined(separator: " → "))
    }
    if Format.available(context.source) {
      lines.append("Source: \(Format.inline(Format.url(context.source), limit: 512))")
    }
    let preferred = locator.isEmpty ? context.selector : locator
    if !preferred.isEmpty { lines.append("Locator: \(Format.code(preferred, limit: 512))") }
    if Format.available(context.role) {
      lines.append("Role: \(Format.inline(context.role, limit: 80))")
    }
    if !context.accessibleName.isEmpty {
      lines.append("Name: \(Format.inline(context.accessibleName, limit: 160))")
    }
    lines.append(
      "Box: \(Format.number(context.bounds.width.rounded())) × \(Format.number(context.bounds.height.rounded()))"
    )
    let names: Set<String> = [
      "display", "position", "font-size", "font-family", "font-weight", "color", "background-color",
      "padding", "margin",
    ]
    let styles = context.styles.filter { names.contains($0.name) && !$0.value.isEmpty }.prefix(8)
    if !styles.isEmpty {
      lines.append(
        "Styles: "
          + styles.map { "\($0.name): \(Format.inline($0.value, limit: 80))" }.joined(
            separator: "; "))
    }
    let html = Format.html(context.html)
    if !html.isEmpty { lines.append("HTML: \(Format.code(String(html.prefix(900)), limit: 900))") }
    let output = lines.joined(separator: "\n") + "\n"
    guard output.utf8.count > 4096 else { return output }
    return String(decoding: output.utf8.prefix(4000), as: UTF8.self) + "…\n"
  }
}

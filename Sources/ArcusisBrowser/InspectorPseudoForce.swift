// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

enum InspectorPseudoForce {
  static let names = ["hover", "active", "focus", "focus-visible", "focus-within"]

  /// Longer tokens first so ":focus" does not claim ":focus-visible".
  private static let tokens = ["focus-visible", "focus-within", "hover", "active", "focus"]

  static func ordered(_ states: some Sequence<String>) -> [String] {
    let selected = Set(states)
    return names.filter { selected.contains($0) }
  }

  static func state(in selector: String) -> String? {
    for token in tokens where selector.contains(":\(token)") {
      return token
    }
    return nil
  }

  /// Drop matched rules that use a managed pseudo, then append one fixture rule per enabled state.
  static func matched(
    _ payload: [String: Any], states: some Sequence<String>, rules: [String: [String: Any]]
  ) -> [String: Any] {
    var next = payload
    let rows = (payload["matchedCSSRules"] as? [[String: Any]]) ?? []
    let kept = rows.filter { state(in: selectorText($0)) == nil }
    let added = ordered(states).compactMap { rules[$0] }
    next["matchedCSSRules"] = kept + added
    return next
  }

  static func selectors(in payload: [String: Any]) -> [String] {
    let rows = (payload["matchedCSSRules"] as? [[String: Any]]) ?? []
    return rows.map(selectorText)
  }

  static func selectorText(_ row: [String: Any]) -> String {
    guard let rule = row["rule"] as? [String: Any],
      let list = rule["selectorList"] as? [String: Any],
      let text = list["text"] as? String
    else { return "" }
    return text
  }
}

struct InspectorPseudoForceControls: View {
  var forced: Set<String>
  var toggle: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(InspectorL10n.string("Force state"))
        .font(.system(size: 11, weight: .semibold))
      HStack(spacing: 6) {
        control("hover")
        control("active")
        control("focus")
      }
      HStack(spacing: 6) {
        control("focus-visible")
        control("focus-within")
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func control(_ name: String) -> some View {
    let on = forced.contains(name)
    return Button {
      toggle(name)
    } label: {
      Text(":\(name)")
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(on ? Color.white : Color.primary)
        .background(on ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .overlay {
          RoundedRectangle(cornerRadius: 5)
            .strokeBorder(Color.secondary.opacity(on ? 0 : 0.45), lineWidth: 1)
        }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(":\(name)")
    .accessibilityAddTraits(on ? .isSelected : [])
  }
}

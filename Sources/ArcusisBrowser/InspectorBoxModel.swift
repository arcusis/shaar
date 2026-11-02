// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct InspectorBoxModel: View {
  let box: InspectorSelection.Box
  var highlight: ((String, Int, Bool) -> Void)? = nil
  @State private var hovered: String?
  var body: some View {
    ZStack {
      ring("margin", values: box.margin, inset: 0)
      ring("border", values: box.border, inset: 18)
      ring("padding", values: box.padding, inset: 36)
      RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.035))
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(.primary.opacity(0.14)))
        .padding(54)
      Text(
        "\(InspectorColor.number(box.contentWidth.rounded())) × \(InspectorColor.number(box.contentHeight.rounded()))"
      )
      .font(.system(size: 11, weight: .medium, design: .monospaced))
    }.frame(height: 142).environment(\.layoutDirection, .leftToRight)
      .accessibilityElement(children: .contain)
      .accessibilityLabel(
        InspectorL10n.format(
          "Box model. Content %@ by %@ pixels.",
          arguments: [
            .string(InspectorColor.number(box.contentWidth.rounded())),
            .string(InspectorColor.number(box.contentHeight.rounded())),
          ])
      )
  }

  private func ring(_ name: String, values: [String], inset: CGFloat) -> some View {
    GeometryReader { geometry in
      let width = max(0, geometry.size.width - inset * 2)
      let height = max(0, geometry.size.height - inset * 2)
      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.02))
          .overlay(
            RoundedRectangle(cornerRadius: 2).strokeBorder(
              .primary.opacity(0.13),
              style: StrokeStyle(lineWidth: 0.5, dash: name == "margin" ? [3, 2] : [])))
        InspectorL10n.text(name.capitalized).font(.system(size: 9)).foregroundStyle(.tertiary)
          .offset(x: 5, y: 3)
        if values.count == 4 {
          value(values[0], region: name, index: 0).position(x: width / 2, y: 10)
          value(values[1], region: name, index: 1).position(x: width - 10, y: height / 2)
          value(values[2], region: name, index: 2).position(x: width / 2, y: height - 10)
          value(values[3], region: name, index: 3).position(x: 10, y: height / 2)
        }
      }.frame(width: width, height: height).offset(x: inset, y: inset)
    }
  }

  private func value(_ raw: String, region: String, index: Int) -> some View {
    let text = raw.replacingOccurrences(of: "px", with: "")
    let zero = Double(text) == 0
    let key = region + String(index)
    let side = ["top", "right", "bottom", "left"][index]
    return Text(zero ? "—" : text)
      .font(.system(size: 10, weight: zero ? .regular : .medium, design: .monospaced))
      .foregroundStyle(zero ? .tertiary : .primary).lineLimit(1)
      .padding(.horizontal, 2).frame(minWidth: 16, minHeight: 16)
      .background(
        .primary.opacity(hovered == key ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 3)
      )
      .contentShape(Rectangle()).help(
        InspectorL10n.format(
          "%@ %@: %@",
          arguments: [
            .string(InspectorL10n.string(region.capitalized)),
            .string(InspectorL10n.string(side.capitalized)), .string(raw),
          ])
      )
      .onHover { active in
        if active { hovered = key } else if hovered == key { hovered = nil }
        highlight?(region, index, active)
      }
  }
}

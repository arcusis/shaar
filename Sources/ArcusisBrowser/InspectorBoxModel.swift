// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct InspectorBoxModel: View {
  let box: InspectorSelection.Box
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    ZStack {
      ring("margin", values: box.margin, color: .orange, inset: 0)
      ring("border", values: box.border, color: .yellow, inset: 22)
      ring("padding", values: box.padding, color: .green, inset: 44)
      RoundedRectangle(cornerRadius: 2).fill(Color.blue.opacity(scheme == .dark ? 0.18 : 0.12))
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.blue.opacity(0.25)))
        .padding(.horizontal, 66).padding(.vertical, 66)
      Text(
        "\(InspectorColor.number(box.contentWidth)) × \(InspectorColor.number(box.contentHeight))"
      )
      .font(.system(size: 11, weight: .medium, design: .monospaced))
    }
    .frame(height: 176)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "Box model. Content \(InspectorColor.number(box.contentWidth)) by \(InspectorColor.number(box.contentHeight)) pixels."
    )
  }

  private func ring(_ name: String, values: [String], color: Color, inset: CGFloat) -> some View {
    GeometryReader { geometry in
      let width = geometry.size.width - inset * 2
      let height = geometry.size.height - inset * 2
      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: 2).fill(color.opacity(scheme == .dark ? 0.1 : 0.09))
          .overlay(
            RoundedRectangle(cornerRadius: 2).strokeBorder(
              .primary.opacity(0.12),
              style: StrokeStyle(lineWidth: 0.5, dash: name == "margin" ? [3, 2] : [])))
        Text(name).font(.system(size: 10)).foregroundStyle(.secondary).offset(x: 6, y: 4)
        if values.count == 4 {
          value(values[0]).position(x: width / 2, y: 11)
          value(values[2]).position(x: width / 2, y: height - 11)
          value(values[3]).position(x: 11, y: height / 2)
          value(values[1]).position(x: width - 11, y: height / 2)
        }
      }.frame(width: width, height: height).offset(x: inset, y: inset)
    }
  }
  private func value(_ text: String) -> some View {
    Text(text.replacingOccurrences(of: "px", with: ""))
      .font(.system(size: 10, design: .monospaced)).lineLimit(1)
  }
}

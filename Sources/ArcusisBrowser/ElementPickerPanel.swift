// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct ElementPickerPanel: View {
  let element: PickedElement
  let copy: (String) -> Void
  let close: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label(
          "\(element.tag) · \(Int(element.width.rounded())) × \(Int(element.height.rounded()))",
          systemImage: "scope"
        ).font(.callout.weight(.semibold))
        Spacer()
        Button(action: close) { Image(systemName: "xmark").frame(width: 20, height: 20) }
          .buttonStyle(.plain).help("Exit element picker").accessibilityLabel("Exit element picker")
      }
      row("CSS selector", element.css)
      row("XPath", element.xpath)
      row("Playwright", element.playwright)
      if !element.frames.isEmpty {
        Text("Frame: \(element.frames.joined(separator: " › "))").font(.caption).foregroundStyle(
          .secondary
        )
        .fixedSize(horizontal: false, vertical: true)
        Text("CSS and XPath target this frame's document.").font(.caption2).foregroundStyle(
          .secondary)
      }
      Divider()
      if let component = element.component {
        row(element.framework ?? "Component", component)
        if let source = element.source { row("Source", source) }
      } else {
        Text("Component information is not exposed by this page.").font(.caption).foregroundStyle(
          .secondary)
      }
      Text("Escape exits · Pick again to choose another element").font(.caption2).foregroundStyle(
        .secondary)
    }
    .padding(12)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.12)) }
    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    .onExitCommand(perform: close)
  }

  private func row(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text(title).font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button {
          copy(value)
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.plain).help("Copy \(title)").accessibilityLabel("Copy \(title)")
      }
      Text(value).font(.system(.caption, design: .monospaced)).lineLimit(3)
        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }
  }
}

struct DeveloperPickerSection: View {
  let model: SiteControlsDeveloperModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Button(model.pickerEnabled ? "Pick Again" : "Pick Element") {
          Task {
            await model.startPicker()
            if model.pickerEnabled { dismiss() }
          }
        }
        .help("Pick an element (Command-Option-C)")
        if model.pickerEnabled { Button("Exit Picker") { model.stopPicker() } }
      }
      Text("Hover to inspect, click to copy selectors. Same-origin frames supported.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if let failure = model.pickerFailure { Text(failure).font(.caption).foregroundStyle(.red) }
    }
  }
}

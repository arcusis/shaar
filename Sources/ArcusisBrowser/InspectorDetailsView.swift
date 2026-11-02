// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct InspectorDetailsView: View {
  @Bindable var inspector: InspectorModel
  @Bindable var model: InspectorDetailsModel

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        if inspector.selection?.locked != true {
          Text("Click an element to lock its details.").font(.system(size: 12))
            .foregroundStyle(.secondary).padding(24)
        } else if model.selectedID != inspector.selection?.id || model.activeTab != inspector.tab {
          ProgressView("Reading details…").controlSize(.small).font(.system(size: 11)).padding(24)
        } else {
          switch inspector.tab {
          case .component: component
          case .accessibility: accessibility
          case .assets: assets
          default: EmptyView()
          }
        }
        if let failure = model.failure {
          Text(failure).font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
      }
    }.scrollBounceBehavior(.basedOnSize)
      .task(id: inspector.documentGeneration) {
        while !Task.isCancelled {
          await model.refresh()
          do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        }
      }
  }

  @ViewBuilder private var component: some View {
    if let tree = model.tree, let framework = tree.framework {
      InspectorSection("\(framework) components") {
        OutlineGroup(branches(tree.nodes, parent: nil), children: \.children) { branch in
          Button {
            Task { await model.selectComponent(branch.id) }
          } label: {
            HStack {
              Image(systemName: "shippingbox").foregroundStyle(.secondary)
              Text(branch.entry.name).font(.system(size: 11, design: .monospaced)).lineLimit(1)
              Spacer(minLength: 0)
              if model.selectedComponent == branch.id {
                Image(systemName: "checkmark").font(.system(size: 9)).foregroundStyle(
                  Color.accentColor)
              }
            }.padding(.vertical, 4).contentShape(Rectangle())
          }.buttonStyle(.plain).help("Inspect \(branch.entry.name) data")
        }
        if let limit = tree.limit {
          Text(limit).font(.system(size: 10)).foregroundStyle(.secondary)
        }
      }
      if let data = model.component {
        InspectorSection(data.name) {
          VStack(alignment: .leading, spacing: 10) {
            if let source = data.source {
              InspectorProperty(
                "Source", value: source.components(separatedBy: "/").last ?? source,
                copyLabel: "source location"
              ) { _ in inspector.copy(source) }
              .help(source)
            } else {
              Text("Source location is not exposed by this build.").font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            if let note = data.note {
              Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if data.truncated {
              Text("Values limited by depth, key count or text length.").font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
          }
        }
        if data.props != "null" {
          InspectorJSONSection(title: "Props", json: data.props, copy: inspector.copy)
        }
        if data.state != "null" {
          InspectorJSONSection(title: "State", json: data.state, copy: inspector.copy)
        }
        if data.hooks != "null" {
          InspectorJSONSection(title: "Hook state slots", json: data.hooks, copy: inspector.copy)
        }
      }
    } else {
      InspectorSection("Component data") {
        Text("No framework component metadata is exposed for this element.")
          .font(.system(size: 12)).foregroundStyle(.secondary)
        Text(
          "Development builds can expose names, source locations, props and state. Svelte source metadata may be available without runtime state."
        )
        .font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder private var accessibility: some View {
    if let data = model.accessibility {
      InspectorSection("Accessibility") {
        VStack(spacing: 2) {
          InspectorProperty("Role", value: data.role, copy: inspector.copy)
          InspectorProperty(
            "Name", value: data.name.isEmpty ? "No accessible name" : data.name,
            copy: inspector.copy)
          InspectorProperty(
            "In tree", value: data.ignored.map { $0 ? "No" : "Yes" } ?? "Unavailable",
            copy: inspector.copy)
          InspectorProperty(
            "Tab order",
            value: data.tabOrder.map { "\($0) · document" } ?? "Not in sequential order",
            copy: inspector.copy
          )
          .help(
            "Document estimate; shadow roots, nested frames and radio groups can change browser tab order."
          )
          ForEach(data.properties) { property in
            InspectorProperty(property.name, value: property.value, copy: inspector.copy)
          }
          if data.tabLimit {
            Text("Tab-order sample limited to 5,000 candidates.").font(.system(size: 10))
              .foregroundStyle(.secondary)
          }
        }
      }
      InspectorSection("ARIA attributes") {
        if data.aria.isEmpty {
          Text("No ARIA attributes").font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
          VStack(spacing: 2) {
            ForEach(data.aria) { property in
              InspectorProperty(property.name, value: property.value, copy: inspector.copy)
            }
          }
        }
      }
      InspectorSection("Checks") {
        VStack(alignment: .leading, spacing: 10) {
          if data.warnings.isEmpty {
            Label("No selected-element warnings", systemImage: "checkmark.circle")
              .font(.system(size: 11)).foregroundStyle(.secondary)
          }
          ForEach(Array(data.warnings.enumerated()), id: \.offset) { _, warning in
            Label(warning, systemImage: "exclamationmark.triangle").font(.system(size: 11))
              .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          }
          Text(
            "Selected-element checks cover names, alt text, duplicate IDs, hidden focus targets and computed contrast."
          )
          .font(.system(size: 10)).foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder private var assets: some View {
    if let data = model.assets {
      InspectorSection("Images") {
        if data.images.isEmpty {
          Text("No images in this selection").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        VStack(spacing: 16) {
          ForEach(data.images) { image in
            VStack(alignment: .leading, spacing: 4) {
              Text(URL(string: image.url)?.lastPathComponent ?? "Image")
                .font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle).help(
                  image.url)
              InspectorProperty(
                "Rendered",
                value:
                  "\(InspectorColor.number(image.renderedWidth)) × \(InspectorColor.number(image.renderedHeight))",
                copy: inspector.copy)
              InspectorProperty(
                "Natural",
                value:
                  "\(InspectorColor.number(image.naturalWidth)) × \(InspectorColor.number(image.naturalHeight))",
                copy: inspector.copy)
              InspectorProperty("Format", value: image.mime ?? "Unavailable", copy: inspector.copy)
              InspectorProperty("Transfer", value: bytes(image.transferSize), copy: inspector.copy)
              if let body = image.bodySize {
                InspectorProperty("Encoded body", value: bytes(body), copy: inspector.copy)
              }
              Text("Transfer may be unavailable for cached or cross-origin resources.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
              HStack {
                Button("Copy URL", systemImage: "doc.on.doc") { inspector.copy(image.url) }
                Button("Download", systemImage: "arrow.down") {
                  if let frame = image.frameID {
                    Task { await model.saveAsset(url: image.url, frameID: frame) }
                  }
                }.disabled(image.frameID == nil)
              }.controlSize(.small).font(.system(size: 11)).padding(.top, 6)
            }
          }
        }
      }
      if let svg = data.svg {
        InspectorSection("SVG") {
          VStack(alignment: .leading, spacing: 10) {
            Text("\(svg.utf8.count.formatted()) bytes of markup").font(
              .system(size: 11, design: .monospaced)
            ).foregroundStyle(.secondary)
            Button("Copy SVG", systemImage: "doc.on.doc") { inspector.copy(svg) }
              .controlSize(.small).font(.system(size: 11)).disabled(data.svgTruncated)
            if data.svgTruncated {
              Text("SVG exceeds the 256 KiB copy limit.").font(.system(size: 10)).foregroundStyle(
                .secondary)
            }
          }
        }
      }
      InspectorSection("Fonts") {
        VStack(alignment: .leading, spacing: 10) {
          Text(inspector.selection?.pageFonts.joined(separator: " · ") ?? "")
            .font(.system(size: 11, design: .monospaced)).fixedSize(
              horizontal: false, vertical: true)
          ForEach(data.fonts) { font in
            HStack {
              Text(URL(string: font.url)?.lastPathComponent ?? font.mime)
                .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
              Spacer(minLength: 0)
              InspectorIconButton("Download font file", symbol: "arrow.down") {
                Task { await model.saveAsset(url: font.url, frameID: font.frameID) }
              }
            }.help(font.url)
          }
          Text(
            "Rendered names come from sampled text. Loaded font files are listed separately; system fonts have no page resource."
          )
          .font(.system(size: 10)).foregroundStyle(.secondary)
        }
      }
    }
  }

  private func bytes(_ value: Double?) -> String {
    value.map {
      ByteCountFormatter.string(
        fromByteCount: Int64(min($0, Double(Int64.max) / 2)), countStyle: .file)
    } ?? "Unavailable"
  }
  private struct Branch: Identifiable {
    let entry: InspectorComponentTree.Entry
    let children: [Branch]?
    var id: Int { entry.id }
  }
  private func branches(_ entries: [InspectorComponentTree.Entry], parent: Int?, depth: Int = 0)
    -> [Branch]
  {
    guard depth < 16 else { return [] }
    return entries.filter { $0.parent == parent }.map { entry in
      let children = branches(entries, parent: entry.id, depth: depth + 1)
      return Branch(entry: entry, children: children.isEmpty ? nil : children)
    }
  }
}

private struct InspectorJSONSection: View {
  let title: String
  let json: String
  let copy: (String) -> Void
  var body: some View {
    InspectorSection(title, copy: copyValue) {
      VStack(alignment: .leading, spacing: 8) {
        Text(json).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
          .lineLimit(20).frame(maxWidth: .infinity, alignment: .leading)
        if json.split(separator: "\n").count > 20 {
          Text("Preview limited to 20 lines; Copy includes the bounded snapshot.")
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
      }
    }
  }
  private func copyValue() { copy(json) }
}

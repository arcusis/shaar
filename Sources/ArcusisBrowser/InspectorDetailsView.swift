// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

enum InspectorComponentAccessibility {
  static func traits(isSelected: Bool) -> AccessibilityTraits {
    isSelected ? .isSelected : []
  }
}

struct InspectorDetailsView: View {
  @Bindable var inspector: InspectorModel
  @Bindable var model: InspectorDetailsModel

  static func componentSelectionTraits(isSelected: Bool) -> AccessibilityTraits {
    isSelected ? .isSelected : []
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        if inspector.tab == .accessibility {
          InspectorAuditView(model: model.audit, inspector: inspector)
        }
        if inspector.selection?.locked != true {
          InspectorDetailsL10n.text("Click an element to lock its details.").font(.system(size: 12))
            .foregroundStyle(.secondary).padding(24)
        } else if model.selectedID != inspector.selection?.id || model.activeTab != inspector.tab {
          ProgressView(InspectorDetailsL10n.string("Reading details…")).controlSize(.small)
            .font(.system(size: 11)).padding(24)
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
      InspectorSection(
        InspectorDetailsL10n.format(
          "%1$@ components", arguments: [.string(framework)])
      ) {
        OutlineGroup(branches(tree.nodes, parent: nil), children: \.children) { branch in
          Button {
            Task { await model.selectComponent(branch.id) }
          } label: {
            HStack {
              Image(systemName: "shippingbox").foregroundStyle(.secondary)
              Text(branch.entry.name)
                .font(.system(size: 11, design: .monospaced)).lineLimit(1)
              Spacer(minLength: 0)
              if model.selectedComponent == branch.id {
                Image(systemName: "checkmark").font(.system(size: 9)).foregroundStyle(
                  Color.accentColor)
              }
            }.padding(.vertical, 4).contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(
            InspectorComponentAccessibility.traits(
              isSelected: model.selectedComponent == branch.id))
          .help(
            InspectorDetailsL10n.format(
              "Inspect %1$@ data", arguments: [.string(branch.entry.name)]
            ))
            .accessibilityAddTraits(
              Self.componentSelectionTraits(isSelected: model.selectedComponent == branch.id))
        }
        if let limit = tree.limit {
          Text(InspectorDetailsL10n.string(limit)).font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
      }
      if let data = model.component {
        InspectorSection(data.name) {
          VStack(alignment: .leading, spacing: 10) {
            if let source = data.source {
              InspectorProperty(
                InspectorDetailsL10n.string("Source"),
                value: source.components(separatedBy: "/").last ?? source,
                copyLabel: InspectorDetailsL10n.string("source location")
              ) { _ in inspector.copy(source) }
              .help(source)
            } else {
              InspectorDetailsL10n.text("Source location is not exposed by this build.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            if let note = data.note {
              Text(InspectorDetailsL10n.string(note)).font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            if data.truncated {
              InspectorDetailsL10n.text("Values limited by depth, key count or text length.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
          }
        }
        if data.props != "null" {
          InspectorJSONSection(
            title: InspectorDetailsL10n.string("Props"), json: data.props, copy: inspector.copy)
        }
        if data.state != "null" {
          InspectorJSONSection(
            title: InspectorDetailsL10n.string("State"), json: data.state, copy: inspector.copy)
        }
        if data.hooks != "null" {
          InspectorJSONSection(
            title: InspectorDetailsL10n.string("Hook state slots"), json: data.hooks,
            copy: inspector.copy)
        }
      }
    } else {
      InspectorSection(InspectorDetailsL10n.string("Component data")) {
        InspectorDetailsL10n.text("No framework component metadata is exposed for this element.")
          .font(.system(size: 12)).foregroundStyle(.secondary)
        InspectorDetailsL10n.text(
          "Development builds can expose names, source locations, props and state. Svelte source metadata may be available without runtime state."
        )
        .font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }
  }

  private var contrastSelection: InspectorSelection? {
    guard let selection = inspector.selection else { return nil }
    if selection.contrast == nil, selection.contrastLimit == nil { return nil }
    return selection
  }

  @ViewBuilder private var accessibility: some View {
    if let data = model.accessibility {
      InspectorSection(InspectorDetailsL10n.string("Accessibility")) {
        VStack(spacing: 2) {
          InspectorProperty(
            InspectorDetailsL10n.string("Role"),
            value: data.role == "Unavailable"
              ? InspectorDetailsL10n.string("Unavailable") : data.role,
            copy: inspector.copy)
          InspectorProperty(
            InspectorDetailsL10n.string("Name"),
            value: data.name.isEmpty
              ? InspectorDetailsL10n.string("No accessible name") : data.name,
            copy: inspector.copy)
          if let source = data.nameSource {
            InspectorProperty(
              InspectorDetailsL10n.string("Source"),
              value: InspectorDetailsL10n.string(source),
              copy: inspector.copy)
          }
          if let selection = contrastSelection {
            InspectorContrastLine(selection: selection).padding(.top, 6)
          }
          InspectorProperty(
            InspectorDetailsL10n.string("In tree"),
            value: data.ignored.map {
              InspectorDetailsL10n.string($0 ? "No" : "Yes")
            } ?? InspectorDetailsL10n.string("Unavailable"),
            copy: inspector.copy)
          InspectorProperty(
            InspectorDetailsL10n.string("Tab order"),
            value: data.tabOrder.map {
              InspectorDetailsL10n.format(
                "%1$@ · document", arguments: [.string(String($0))])
            } ?? InspectorDetailsL10n.string("Not in sequential order"),
            copy: inspector.copy
          )
          .help(
            InspectorDetailsL10n.string(
              "Document estimate; shadow roots, nested frames and radio groups can change browser tab order."
            )
          )
          ForEach(data.properties) { property in
            InspectorProperty(property.name, value: property.value, copy: inspector.copy)
          }
          if data.tabLimit {
            InspectorDetailsL10n.text("Tab-order sample limited to 5,000 candidates.")
              .font(.system(size: 10))
              .foregroundStyle(.secondary)
          }
        }
      }
      InspectorSection(InspectorDetailsL10n.string("ARIA attributes")) {
        if data.aria.isEmpty {
          InspectorDetailsL10n.text("No ARIA attributes").font(.system(size: 11))
            .foregroundStyle(.secondary)
        } else {
          VStack(spacing: 2) {
            ForEach(data.aria) { property in
              InspectorProperty(property.name, value: property.value, copy: inspector.copy)
            }
          }
        }
      }
      InspectorSection(InspectorDetailsL10n.string("Checks")) {
        VStack(alignment: .leading, spacing: 10) {
          if data.warnings.isEmpty {
            Label(
              InspectorDetailsL10n.string("No selected-element warnings"),
              systemImage: "checkmark.circle"
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
          }
          ForEach(Array(data.warnings.enumerated()), id: \.offset) { _, warning in
            Label(InspectorDetailsL10n.string(warning), systemImage: "exclamationmark.triangle")
              .font(.system(size: 11))
              .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          }
          InspectorDetailsL10n.text(
            "Selected-element checks cover names, alt text, duplicate IDs, hidden focus targets and computed contrast."
          )
          .font(.system(size: 10)).foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder private var assets: some View {
    if let data = model.assets {
      InspectorSection(InspectorDetailsL10n.string("Images")) {
        if data.images.isEmpty {
          InspectorDetailsL10n.text("No images in this selection").font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        VStack(spacing: 16) {
          ForEach(data.images) { image in
            VStack(alignment: .leading, spacing: 4) {
              Text(
                URL(string: image.url).map { $0.lastPathComponent }
                  ?? InspectorDetailsL10n.string("Image")
              )
              .font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle).help(
                image.url)
              InspectorProperty(
                InspectorDetailsL10n.string("Rendered"),
                value:
                  "\(InspectorColor.number(image.renderedWidth)) × \(InspectorColor.number(image.renderedHeight))",
                copy: inspector.copy)
              InspectorProperty(
                InspectorDetailsL10n.string("Natural"),
                value:
                  "\(InspectorColor.number(image.naturalWidth)) × \(InspectorColor.number(image.naturalHeight))",
                copy: inspector.copy)
              InspectorProperty(
                InspectorDetailsL10n.string("Format"),
                value: image.mime
                  ?? InspectorDetailsL10n.string("Unavailable"),
                copy: inspector.copy)
              InspectorProperty(
                InspectorDetailsL10n.string("Transfer"), value: bytes(image.transferSize),
                copy: inspector.copy)
              if let body = image.bodySize {
                InspectorProperty(
                  InspectorDetailsL10n.string("Encoded body"), value: bytes(body),
                  copy: inspector.copy)
              }
              InspectorDetailsL10n.text(
                "Transfer may be unavailable for cached or cross-origin resources."
              )
              .font(.system(size: 10)).foregroundStyle(.secondary)
              HStack {
                Button(InspectorDetailsL10n.string("Copy URL"), systemImage: "doc.on.doc") {
                  inspector.copy(image.url)
                }
                Button(InspectorDetailsL10n.string("Download"), systemImage: "arrow.down") {
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
        InspectorSection(InspectorDetailsL10n.string("SVG")) {
          VStack(alignment: .leading, spacing: 10) {
            Text(InspectorDetailsL10n.plural("%d bytes of markup", count: svg.utf8.count)).font(
              .system(size: 11, design: .monospaced)
            ).foregroundStyle(.secondary)
            Button(InspectorDetailsL10n.string("Copy SVG"), systemImage: "doc.on.doc") {
              inspector.copy(svg)
            }
            .controlSize(.small).font(.system(size: 11)).disabled(data.svgTruncated)
            if data.svgTruncated {
              InspectorDetailsL10n.text("SVG exceeds the 256 KiB copy limit.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
          }
        }
      }
      InspectorSection(InspectorDetailsL10n.string("Fonts")) {
        VStack(alignment: .leading, spacing: 10) {
          Text(
            inspector.selection?.pageFonts.joined(separator: " · ") ?? ""
          )
          .font(.system(size: 11, design: .monospaced)).fixedSize(
            horizontal: false, vertical: true)
          ForEach(data.fonts) { font in
            HStack {
              Text(URL(string: font.url)?.lastPathComponent ?? font.mime)
                .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
              Spacer(minLength: 0)
              InspectorIconButton(
                InspectorDetailsL10n.string("Download font file"), symbol: "arrow.down"
              ) {
                Task { await model.saveAsset(url: font.url, frameID: font.frameID) }
              }
            }.help(font.url)
          }
          InspectorDetailsL10n.text(
            "Rendered names come from sampled text. Loaded font files are listed separately; system fonts have no page resource."
          )
          .font(.system(size: 10)).foregroundStyle(.secondary)
        }
      }
    }
  }

  private func bytes(_ value: Double?) -> String {
    guard let value else { return InspectorDetailsL10n.string("Unavailable") }
    return PanelsL10n.byteCount(Int64(min(value, Double(Int64.max) / 2)))
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

enum InspectorComponentRowAccessibility {
  static func traits(isSelected: Bool) -> AccessibilityTraits {
    isSelected ? .isSelected : []
  }
}

private struct InspectorJSONSection: View {
  let title: String
  let json: String
  let copy: (String) -> Void
  var body: some View {
    InspectorSection(title, copy: copyValue) {
      VStack(alignment: .leading, spacing: 8) {
        Text(json).environment(\.layoutDirection, .leftToRight).font(
          .system(size: 11, design: .monospaced)
        ).textSelection(.enabled)
          .lineLimit(20).frame(maxWidth: .infinity, alignment: .leading)
        if json.split(separator: "\n").count > 20 {
          InspectorDetailsL10n.text(
            "Preview limited to 20 lines; Copy includes the bounded snapshot."
          )
          .font(.system(size: 10)).foregroundStyle(.secondary)
        }
      }
    }
  }
  private func copyValue() { copy(json) }
}

// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShaarSourcesPanel: View {
  @Bindable var model: ShaarSourcesModel
  let inspector: InspectorModel?
  @AppStorage("inspectorSourceEditor") private var sourceEditor = InspectorSourceEditor.vscode
    .rawValue
  @FocusState private var focusedURL: String?
  @State private var localSourceStatus: String?
  @State private var choosingProjectFolder = false

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Divider()
      sourceContent.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .task { await model.refresh() }
    .onChange(of: model.selectedURL) { _, _ in localSourceStatus = nil }
    .fileImporter(
      isPresented: $choosingProjectFolder, allowedContentTypes: [.folder]
    ) { result in
      guard case .success(let folder) = result else { return }
      Task {
        await model.findLocalFiles(
          framework: inspector?.engine?.detectedFramework,
          workspaceRootOverride: folder.path)
      }
    }
    .accessibilityIdentifier("shaar.devtools.sourcesPanel")
  }

  private var sidebar: some View {
    VStack(spacing: 0) {
      TextField(ShellL10n.string("Filter resources"), text: $model.search)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 10))
        .padding(8)
      Divider()
      if model.loading && model.resources.isEmpty {
        ProgressView().controlSize(.small).padding(24)
        Spacer()
      } else if model.visibleResources.isEmpty {
        Text(
          ShellL10n.string(
            model.resources.isEmpty ? "No resources loaded" : "No matching resources")
        )
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .padding(12)
        Spacer()
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(folders, id: \.self) { folder in
              Text(folder.isEmpty ? ShellL10n.string("Resources") : folder)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .padding(.horizontal, 12).padding(.top, 11).padding(.bottom, 5)
              ForEach(model.visibleResources.filter { $0.folder == folder }) { resource in
                resourceRow(resource)
              }
            }
          }
        }
        .onMoveCommand { direction in
          guard focusedURL != nil else { return }
          Task {
            if direction == .down { await model.selectAdjacent(forward: true) }
            if direction == .up { await model.selectAdjacent(forward: false) }
            focusedURL = model.selectedURL
          }
        }
      }
      Divider()
      Text(ShellL10n.format("%d resources loaded", arguments: [.integer(model.resources.count)]))
        .font(.system(size: 9)).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).frame(height: 31)
    }
    .frame(width: 220).frame(maxHeight: .infinity)
    .background(Color.primary.opacity(0.025))
  }

  private var folders: [String] {
    Array(Set(model.visibleResources.map(\.folder))).sorted {
      if $0.hasPrefix("/") != $1.hasPrefix("/") { return !$0.hasPrefix("/") }
      return $0 < $1
    }
  }

  private func resourceRow(_ resource: ShaarSourceResource) -> some View {
    Button {
      focusedURL = resource.url
      Task { await model.select(resource) }
    } label: {
      HStack(spacing: 7) {
        Image(systemName: symbol(for: resource)).frame(width: 13)
          .foregroundStyle(.secondary)
        Text(resource.name).lineLimit(1)
        Spacer(minLength: 0)
      }
      .font(.system(size: 10))
      .padding(.horizontal, 12)
      .frame(height: 27)
      .background(model.selectedURL == resource.url ? Color.accentColor.opacity(0.10) : .clear)
    }
    .buttonStyle(.plain)
    .focusable()
    .focused($focusedURL, equals: resource.url)
    .accessibilityIdentifier("shaar.devtools.sourceRow")
  }

  private func symbol(for resource: ShaarSourceResource) -> String {
    switch resource.type.lowercased() {
    case "document": "doc.text"
    case "script": "chevron.left.forwardslash.chevron.right"
    case "stylesheet": "paintbrush"
    case "image": "photo"
    default: "doc"
    }
  }

  private var sourceContent: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if let message = model.sourceFailure ?? localSourceStatus {
        HStack(spacing: 8) {
          Text(message).foregroundStyle(.secondary)
          Spacer(minLength: 0)
          if model.isDevelopmentPage && model.sourceFailure != nil {
            Button(ShellL10n.string("Choose project folder…")) {
              choosingProjectFolder = true
            }
          }
        }
        .font(.system(size: 10))
        .padding(.horizontal, 12).padding(.vertical, 7)
        Divider()
      }
      if let failure = model.failure {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
          Text(failure).lineLimit(2)
          Spacer()
          Button(ShellL10n.string("Retry")) { Task { await model.refresh() } }
        }
        .font(.system(size: 10)).padding(10)
        Divider()
      }
      if model.contentLoading {
        ProgressView().controlSize(.small)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if model.binary {
        emptyContent("Binary resource preview is unavailable")
      } else if let content = model.displayedContent {
        codeView(content)
      } else {
        emptyContent("Select a resource to view its source")
      }
      if model.truncated {
        Text(ShellL10n.string("Resource preview or list is limited"))
          .font(.system(size: 9)).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
      }
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: "doc.text").foregroundStyle(.secondary)
      Text(model.selected?.name ?? ShellL10n.string("Sources"))
        .font(.system(size: 11, weight: .semibold)).lineLimit(1)
      Spacer(minLength: 4)
      Toggle(ShellL10n.string("Pretty JSON"), isOn: $model.prettyPrint)
        .toggleStyle(.checkbox).controlSize(.small)
        .disabled(!model.isJSON)
      if model.isDevelopmentPage {
        Button(ShellL10n.string("Find local files")) {
          localSourceStatus = nil
          Task { await model.findLocalFiles(framework: inspector?.engine?.detectedFramework) }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10))
        .disabled(model.selected == nil || model.sourceLoading)
        .help(ShellL10n.string("Map this resource using the development server and source map"))
        if !model.localFiles.isEmpty {
          Menu(ShellL10n.string("Open local file")) {
            ForEach(model.localFiles, id: \.path) { file in
              Button(localFileLabel(file)) {
                openLocalFile(file)
              }
            }
          }
          .font(.system(size: 10))
        }
      }
      Button(ShellL10n.string("Open selected element source")) {
        Task { await inspector?.sourceActions.open() }
      }
      .buttonStyle(.plain)
      .font(.system(size: 10))
      .disabled(inspector?.aiCopy.canCopy != true)
      .help(ShellL10n.string("Uses the Inspector source resolver"))
      Menu {
        ForEach(InspectorSourceEditor.allCases) { editor in
          Button(editor.label) { sourceEditor = editor.rawValue }
        }
      } label: {
        Image(systemName: "chevron.down").frame(width: 18, height: 22)
      }
      .menuStyle(.borderlessButton)
      .help(ShellL10n.string("Choose source editor"))
      Button {
        Task { await model.refresh() }
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.plain)
      .help(ShellL10n.string("Refresh resources"))
    }
    .padding(.horizontal, 12).frame(height: 36)
  }

  private func openLocalFile(_ location: InspectorSourceLocation) {
    let editor = InspectorSourceEditor(rawValue: sourceEditor) ?? .vscode
    if editor == .showOnly {
      localSourceStatus = location.path
    } else if !InspectorSourceActions.openLocation(location, editor: editor) {
      localSourceStatus = ShellL10n.string("The selected editor could not open this file")
    }
  }

  private func localFileLabel(_ location: InspectorSourceLocation) -> String {
    guard let root = model.localRoot, location.path.hasPrefix(root + "/") else {
      return (location.path as NSString).lastPathComponent
    }
    return String(location.path.dropFirst(root.count + 1))
  }

  private func emptyContent(_ message: String) -> some View {
    Text(ShellL10n.string(message))
      .font(.system(size: 11)).foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func codeView(_ content: String) -> some View {
    GeometryReader { geometry in
      ScrollView([.horizontal, .vertical]) {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(
            Array(content.split(separator: "\n", omittingEmptySubsequences: false).enumerated()),
            id: \.offset
          ) {
            index, line in
            HStack(alignment: .firstTextBaseline, spacing: 13) {
              Text(String(index + 1))
                .foregroundStyle(.tertiary)
                .frame(width: 38, alignment: .trailing)
              Text(ShaarSourceHighlight.render(String(line)))
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
            }
            .font(.system(size: 10, design: .monospaced))
            .frame(height: 18)
          }
        }
        .padding(.vertical, 8).padding(.trailing, 12)
        .frame(
          minWidth: geometry.size.width, minHeight: geometry.size.height,
          alignment: .topLeading)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("shaar.devtools.sourceCode")
  }
}

enum ShaarSourceHighlight {
  private static let patterns: [(String, NSColor)] = [
    (
      #"\b(?:const|let|var|function|return|import|export|from|class|if|else|async|await|default)\b"#,
      .systemPurple
    ),
    (#"\b\d+(?:\.\d+)?\b"#, .systemOrange),
    (#"<(?:/)?[A-Za-z][^>]*>"#, .systemBlue),
    (#"//.*$|/\*.*?\*/|<!--.*?-->"#, .secondaryLabelColor),
    (#"(?:\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`)"#, .systemGreen),
  ]
  private static let rules: [(NSRegularExpression, NSColor)] = patterns.compactMap {
    pattern, color in
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
    return (expression, color)
  }

  static func render(_ line: String) -> AttributedString {
    let result = NSMutableAttributedString(string: line)
    let range = NSRange(line.startIndex..<line.endIndex, in: line)
    for (expression, color) in rules {
      for match in expression.matches(in: line, range: range) {
        result.addAttribute(.foregroundColor, value: color, range: match.range)
      }
    }
    return AttributedString(result)
  }
}

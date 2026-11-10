// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import UniformTypeIdentifiers

struct ShaarNetworkRulesFile: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  var data: Data

  init(data: Data = Data()) { self.data = data }

  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else {
      throw ShaarNetworkRuleError.invalidDocument
    }
    self.data = data
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

struct ShaarNetworkRulesEditor: View {
  @Bindable var model: ShaarNetworkRulesModel
  let openChromium: () -> Void
  @State private var selectingBodyFile = false
  @State private var importingRules = false
  @State private var exportingRules = false
  @State private var exportFile = ShaarNetworkRulesFile()

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button {
          model.showingRules = false
          model.draft = nil
        } label: {
          Image(systemName: "chevron.left")
        }
        .buttonStyle(.plain)
        Text(ShellL10n.string("Network rules"))
          .font(.system(size: 11, weight: .semibold))
        Spacer()
        if model.available {
          Button {
            model.createNew()
          } label: {
            Image(systemName: "plus")
          }
          .buttonStyle(.plain)
          .help(ShellL10n.string("New rule"))
        }
      }
      .padding(.horizontal, 12).frame(height: 34)
      Divider()
      HStack(spacing: 4) {
        Text(ShellL10n.string(model.projectRoot == nil ? "Site" : "Project"))
          .foregroundStyle(.secondary)
        Text(model.projectLabel).lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 0)
      }
      .font(.system(size: 10))
      .padding(.horizontal, 12).frame(height: 26)
      Divider()
      if !model.available {
        unavailable
      } else if model.draft != nil {
        editor
      } else {
        ruleList
      }
    }
    .accessibilityIdentifier("shaar.devtools.networkRulesEditor")
    .fileImporter(isPresented: $importingRules, allowedContentTypes: [.json]) { result in
      importRules(result)
    }
    .fileExporter(
      isPresented: $exportingRules, document: exportFile, contentType: .json,
      defaultFilename: "network-rules.json"
    ) { result in
      if case .failure(let error) = result { model.failure = error.localizedDescription }
    }
  }

  private func importRules(_ result: Result<URL, Error>) {
    Task {
      do {
        let url = try result.get()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        try await model.importDocument(ShaarNetworkRuleExchange.readFile(at: url))
      } catch {
        model.failure = error.localizedDescription
      }
    }
  }

  private func beginExport() {
    do {
      exportFile = ShaarNetworkRulesFile(data: try model.exportDocument())
      model.failure = nil
      exportingRules = true
    } catch {
      model.failure = error.localizedDescription
    }
  }

  private var unavailable: some View {
    VStack(spacing: 9) {
      Image(systemName: "bolt.slash")
        .font(.system(size: 20, weight: .ultraLight))
        .foregroundStyle(.tertiary)
      Text(ShellL10n.string("Network rules need engine support"))
        .font(.system(size: 11, weight: .medium))
      Text(ShellL10n.string("Saved rules remain off until this tab supports Fetch interception."))
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button(ShellL10n.string("Open Chromium DevTools"), action: openChromium)
        .controlSize(.small)
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("shaar.devtools.networkRulesUnavailable")
  }

  private var ruleList: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Button(ShellL10n.string("Import JSON")) { importingRules = true }
          .buttonStyle(.plain)
          .help(ShellL10n.string("Replaces the saved rules for this site."))
          .accessibilityIdentifier("shaar.devtools.networkRulesImport")
        Button(ShellL10n.string("Export JSON"), action: beginExport)
          .buttonStyle(.plain)
          .disabled(model.rules.isEmpty)
          .accessibilityIdentifier("shaar.devtools.networkRulesExport")
        Spacer(minLength: 0)
      }
      .font(.system(size: 10))
      .padding(.horizontal, 12)
      .frame(height: 28)
      Divider()
      rulesScroll
    }
  }

  private var rulesScroll: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        if model.rules.isEmpty {
          Text(ShellL10n.string("No saved rules for this site"))
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 35)
        }
        ForEach(model.rules) { rule in
          Button {
            model.edit(rule)
          } label: {
            HStack(spacing: 8) {
              Circle()
                .fill(rule.enabled ? Color.orange : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
              VStack(alignment: .leading, spacing: 3) {
                Text("\(rule.method)  \(rule.url)")
                  .font(.system(size: 10, design: .monospaced)).lineLimit(1)
                Text(ShellL10n.string(rule.kind.rawValue))
                  .font(.system(size: 10)).foregroundStyle(.secondary)
              }
              Spacer()
              Image(systemName: "chevron.right")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).frame(height: 44)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          Divider()
        }
      }
    }
  }

  private var editor: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Toggle(ShellL10n.string("Enabled"), isOn: field(\.enabled))
              .toggleStyle(.checkbox)
            Spacer()
            Text(ShellL10n.string(model.draft?.enabled == true ? "On" : "Off"))
              .foregroundStyle(model.draft?.enabled == true ? Color.orange : Color.secondary)
          }
          HStack(spacing: 6) {
            Picker(ShellL10n.string("Method"), selection: field(\.method)) {
              ForEach(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"], id: \.self) {
                Text($0).tag($0)
              }
            }
            .labelsHidden().frame(width: 84)
            TextField(ShellL10n.string("Exact request URL"), text: field(\.url))
              .textFieldStyle(.roundedBorder)
          }
          Picker(ShellL10n.string("Action"), selection: field(\.kind)) {
            ForEach(ShaarNetworkRuleKind.allCases, id: \.self) { kind in
              Text(ShellL10n.string(kind.rawValue)).tag(kind)
            }
          }
          .pickerStyle(.menu)
          actionFields
          if let failure = model.failure {
            Text(failure).font(.system(size: 10)).foregroundStyle(.red)
          }
        }
        .font(.system(size: 10))
        .padding(12)
      }
      Divider()
      HStack {
        if let draft = model.draft,
          model.rules.contains(where: { $0.id == draft.id })
        {
          Button(ShellL10n.string("Delete"), role: .destructive) {
            Task { try? await model.remove(draft) }
          }
          .buttonStyle(.plain)
        }
        Spacer()
        Button(ShellL10n.string("Cancel")) { model.draft = nil }
          .buttonStyle(.plain)
        Button(ShellL10n.string("Save rule")) {
          Task {
            do { try await model.saveDraft() } catch { model.failure = error.localizedDescription }
          }
        }
        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
      }
      .font(.system(size: 10)).padding(.horizontal, 12).frame(height: 34)
    }
  }

  @ViewBuilder private var actionFields: some View {
    switch model.draft?.kind {
    case .mock:
      TextField(ShellL10n.string("Response status"), value: field(\.status), format: .number)
        .textFieldStyle(.roundedBorder)
      headerFields
      HStack {
        Text(ShellL10n.string("Response body"))
        Spacer()
        Button(ShellL10n.string("Choose file…")) { selectingBodyFile = true }
          .buttonStyle(.plain)
      }
      if let path = model.draft?.bodyFilePath {
        Text(path).lineLimit(2).foregroundStyle(.secondary)
        Button(ShellL10n.string("Use text instead")) {
          model.draft?.bodyFilePath = nil
        }
        .buttonStyle(.plain)
      } else {
        TextEditor(text: field(\.bodyText))
          .font(.system(size: 10, design: .monospaced))
          .frame(height: 92)
          .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.1)))
      }
    case .redirect:
      TextField(ShellL10n.string("Redirect URL"), text: field(\.redirectURL))
        .textFieldStyle(.roundedBorder)
    case .delay:
      TextField(
        ShellL10n.string("Delay (ms)"), value: field(\.delayMilliseconds), format: .number
      )
      .textFieldStyle(.roundedBorder)
    case .requestHeaders, .responseHeaders:
      headerFields
    case nil:
      EmptyView()
    }
  }

  private var headerFields: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(ShellL10n.string("Headers"))
        Spacer()
        Button(ShellL10n.string("Add header")) {
          model.draft?.headers.append(.init(name: "", value: ""))
        }
        .buttonStyle(.plain)
      }
      ForEach(0..<(model.draft?.headers.count ?? 0), id: \.self) { index in
        HStack(spacing: 4) {
          TextField(ShellL10n.string("Name"), text: header(index, \.name))
          TextField(ShellL10n.string("Value"), text: header(index, \.value))
          Button {
            model.draft?.headers.remove(at: index)
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.plain)
        }
        .textFieldStyle(.roundedBorder)
      }
    }
    .fileImporter(isPresented: $selectingBodyFile, allowedContentTypes: [.data]) { result in
      if case .success(let url) = result { model.draft?.bodyFilePath = url.path }
    }
  }

  private func field<Value>(_ keyPath: WritableKeyPath<ShaarNetworkRule, Value>) -> Binding<Value> {
    Binding(
      get: { model.draft?[keyPath: keyPath] ?? ShaarNetworkRule()[keyPath: keyPath] },
      set: { model.draft?[keyPath: keyPath] = $0 })
  }

  private func header(_ index: Int, _ keyPath: WritableKeyPath<ShaarNetworkHeader, String>)
    -> Binding<String>
  {
    Binding(
      get: {
        guard let headers = model.draft?.headers, headers.indices.contains(index) else { return "" }
        return headers[index][keyPath: keyPath]
      },
      set: {
        guard model.draft?.headers.indices.contains(index) == true else { return }
        model.draft?.headers[index][keyPath: keyPath] = $0
      })
  }
}

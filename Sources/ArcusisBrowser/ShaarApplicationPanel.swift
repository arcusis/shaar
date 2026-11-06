// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct ShaarApplicationPanel: View {
  @Bindable var model: ShaarApplicationModel
  let phase2: ShaarPhase2Model
  let openChromium: () -> Void
  let clearCookies: (() async throws -> Void)?
  let clearSiteData: (() async throws -> Void)?
  @FocusState private var focusedRow: String?
  @State private var editing = false
  @State private var editorKey = ""
  @State private var editorValue = ""
  @State private var confirmation: Confirmation?

  private enum Confirmation: Equatable {
    case removeStorage(String)
    case clearStorage
    case clearCookies
    case clearSiteData
    case unregisterWorker(String)

    var title: String {
      switch self {
      case .removeStorage: "Delete storage item?"
      case .clearStorage: "Clear this storage area?"
      case .clearCookies: "Clear cookies for this page?"
      case .clearSiteData: "Clear site data?"
      case .unregisterWorker: "Unregister service worker?"
      }
    }
  }

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Divider()
      mainContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .task(id: model.selectionKey) { await model.refresh() }
    .onChange(of: phase2.available) { _, available in
      if available { Task { await model.refresh() } } else { model.reset() }
    }
    .onChange(of: phase2.events) { _, events in model.receive(events) }
    .confirmationDialog(
      ShellL10n.string(confirmation?.title ?? "Confirm action"),
      isPresented: Binding(
        get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
      titleVisibility: .visible
    ) {
      Button(ShellL10n.string("Confirm"), role: .destructive) {
        let action = confirmation
        confirmation = nil
        Task { await perform(action) }
      }
      Button(ShellL10n.string("Cancel"), role: .cancel) { confirmation = nil }
    }
    .accessibilityIdentifier("shaar.devtools.applicationPanel")
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      groupLabel("Storage")
      ForEach(ShaarApplicationArea.allCases.prefix(5), id: \.self) { area in
        areaButton(area)
      }
      groupLabel("Background")
      areaButton(.workers)
      Spacer()
      Button(ShellL10n.string("Clear site data…")) { confirmation = .clearSiteData }
        .buttonStyle(.plain)
        .font(.system(size: 10))
        .foregroundStyle(clearSiteData == nil ? .tertiary : .secondary)
        .disabled(clearSiteData == nil)
        .padding(12)
    }
    .frame(width: 190).frame(maxHeight: .infinity, alignment: .topLeading)
    .background(Color.primary.opacity(0.025))
  }

  private func groupLabel(_ title: String) -> some View {
    Text(ShellL10n.string(title).uppercased())
      .font(.system(size: 9, weight: .semibold))
      .foregroundStyle(.tertiary)
      .padding(.horizontal, 12).padding(.top, 13).padding(.bottom, 6)
  }

  private func areaButton(_ area: ShaarApplicationArea) -> some View {
    Button {
      editing = false
      model.selectArea(area)
    } label: {
      Label(ShellL10n.string(area.rawValue), systemImage: area.symbol)
        .font(.system(size: 10, weight: model.area == area ? .semibold : .regular))
        .foregroundStyle(model.area == area ? .primary : .secondary)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .background(model.area == area ? Color.accentColor.opacity(0.10) : .clear)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(model.area == area ? .isSelected : [])
  }

  private var mainContent: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if let failure = model.failure {
        HStack {
          Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
          Text(failure).lineLimit(2)
          Spacer()
          Button(ShellL10n.string("Retry")) { Task { await model.refresh() } }
        }
        .font(.system(size: 10)).padding(10)
        Divider()
      }
      if model.area == .cookies {
        cookiesContent
      } else if model.area == .workers {
        workerContent
      } else if model.cacheEntryURL != nil {
        responseContent
      } else {
        tableContent
      }
      Divider()
      footer
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      if model.database != nil || model.cacheID != nil {
        Button {
          model.back()
        } label: {
          Image(systemName: "chevron.left")
        }
        .buttonStyle(.plain)
        .help(ShellL10n.string("Back"))
      }
      Text(ShellL10n.string(model.area.rawValue))
        .font(.system(size: 11, weight: .semibold))
      if let path = model.store ?? model.database ?? model.cacheID {
        Text(path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 4)
      if model.area != .cookies && model.area != .workers {
        TextField(ShellL10n.string("Filter items"), text: $model.search)
          .textFieldStyle(.roundedBorder)
          .font(.system(size: 10))
          .frame(width: 150)
      }
      Button {
        Task { await model.refresh() }
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.plain)
      .help(ShellL10n.string("Refresh application data"))
    }
    .padding(.horizontal, 12)
    .frame(height: 36)
  }

  private var cookiesContent: some View {
    VStack(spacing: 9) {
      Image(systemName: "circle.grid.2x2")
        .font(.system(size: 22, weight: .ultraLight)).foregroundStyle(.tertiary)
      Text(ShellL10n.string("Cookie inspection needs the site-data read route"))
        .font(.system(size: 12, weight: .medium))
      Text(ShellL10n.string("Use Chromium DevTools to inspect or edit individual cookies."))
        .font(.system(size: 11)).foregroundStyle(.secondary)
      Button(ShellL10n.string("Open Chromium DevTools"), action: openChromium)
        .controlSize(.small)
      if clearCookies != nil {
        Button(ShellL10n.string("Clear cookies and reload"), role: .destructive) {
          confirmation = .clearCookies
        }
        .controlSize(.small)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .multilineTextAlignment(.center)
    .padding(20)
  }

  private var workerContent: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        if model.workers.isEmpty { emptyContent("No service workers for this page") }
        ForEach(model.workers) { worker in
          HStack(spacing: 8) {
            Image(systemName: "gearshape.2").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
              Text(worker.scopeURL).font(.system(size: 11, design: .monospaced))
              Text("\(worker.status) · \(worker.scriptURL)")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(ShellL10n.string("Update")) {
              Task { await model.updateWorker(worker) }
            }
            Button(ShellL10n.string("Unregister"), role: .destructive) {
              confirmation = .unregisterWorker(worker.id)
            }
          }
          .controlSize(.small)
          .padding(12)
          Divider()
        }
      }
    }
  }

  private var responseContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        Text(ShellL10n.string("Cached response"))
          .font(.system(size: 11, weight: .semibold))
        if let body = model.body {
          if model.bodyEncoded {
            Text(ShellL10n.string("Binary response is available in Chromium DevTools"))
              .font(.system(size: 11)).foregroundStyle(.secondary)
            Button(ShellL10n.string("Open Chromium DevTools"), action: openChromium)
              .controlSize(.small)
          } else {
            Text(String(body.prefix(32_768)))
              .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
          }
        } else {
          emptyContent("No cached response is available")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
    }
  }

  private var tableContent: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text(ShellL10n.string("Name")).frame(width: 210, alignment: .leading)
        Text(ShellL10n.string("Value")).frame(maxWidth: .infinity, alignment: .leading)
        if model.area == .indexedDB || model.area == .cache {
          Text(ShellL10n.string("Detail")).frame(width: 95, alignment: .leading)
        }
      }
      .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
      .padding(.horizontal, 12).frame(height: 29)
      .background(Color.primary.opacity(0.035))
      ScrollView {
        LazyVStack(spacing: 0) {
          if model.loading {
            ProgressView().controlSize(.small).padding(28)
          } else if model.visibleRows.isEmpty {
            emptyContent(emptyMessage)
          }
          ForEach(model.visibleRows) { row in
            Button {
              select(row)
            } label: {
              HStack(spacing: 8) {
                Text(row.name).frame(width: 210, alignment: .leading).lineLimit(1)
                Text(row.value).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                if model.area == .indexedDB || model.area == .cache {
                  Text(row.detail).frame(width: 95, alignment: .leading).lineLimit(1)
                }
              }
              .font(.system(size: 10, design: .monospaced))
              .padding(.horizontal, 12).frame(height: 35)
              .background(model.selectedID == row.id ? Color.accentColor.opacity(0.10) : .clear)
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($focusedRow, equals: row.id)
            .accessibilityIdentifier("shaar.devtools.applicationRow")
            Divider()
          }
          if model.hasMore {
            Button(ShellL10n.string("Load more")) { Task { await model.loadMore() } }
              .buttonStyle(.plain).font(.system(size: 10)).padding(12)
          }
        }
      }
      .onMoveCommand { direction in
        guard focusedRow != nil else { return }
        if direction == .down { model.selectAdjacent(forward: true) }
        if direction == .up { model.selectAdjacent(forward: false) }
        focusedRow = model.selectedID
      }
      if editing && model.isStorage { storageEditor }
    }
  }

  private var storageEditor: some View {
    HStack(spacing: 8) {
      TextField(ShellL10n.string("Key"), text: $editorKey).frame(width: 180)
      TextField(ShellL10n.string("Value"), text: $editorValue)
      Button(ShellL10n.string("Save")) {
        editing = false
        Task { await model.saveStorage(key: editorKey, value: editorValue) }
      }
      .disabled(editorKey.isEmpty)
      Button(ShellL10n.string("Cancel")) { editing = false }
    }
    .textFieldStyle(.roundedBorder)
    .controlSize(.small)
    .padding(8)
    .onExitCommand { editing = false }
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Text(ShellL10n.format("%d items", arguments: [.integer(model.rows.count)]))
        .foregroundStyle(.secondary)
      Spacer()
      if model.isStorage {
        Button(ShellL10n.string("Add")) { beginEdit(nil) }
        Button(ShellL10n.string("Edit")) {
          beginEdit(model.rows.first { $0.id == model.selectedID })
        }
        .disabled(model.selectedID == nil)
        Button(ShellL10n.string("Delete"), role: .destructive) {
          if let selectedID = model.selectedID { confirmation = .removeStorage(selectedID) }
        }
        .disabled(model.selectedID == nil)
        Button(ShellL10n.string("Clear"), role: .destructive) {
          confirmation = .clearStorage
        }
        .disabled(model.rows.isEmpty)
      }
    }
    .buttonStyle(.plain)
    .font(.system(size: 10))
    .padding(.horizontal, 12)
    .frame(height: 31)
  }

  private var emptyMessage: String {
    if !model.search.isEmpty && !model.rows.isEmpty { return "No matching items" }
    switch model.area {
    case .cookies: return "Cookie inspection needs the site-data read route"
    case .local, .session: return "No storage items for this page"
    case .indexedDB: return "No IndexedDB data for this page"
    case .cache: return "No cached resources for this page"
    case .workers: return "No service workers for this page"
    }
  }

  private func emptyContent(_ message: String) -> some View {
    Text(ShellL10n.string(message))
      .font(.system(size: 11)).foregroundStyle(.secondary)
      .frame(maxWidth: .infinity).padding(.top, 65)
  }

  private func select(_ row: ShaarApplicationRow) {
    model.selectedID = row.id
    focusedRow = row.id
    if model.area == .indexedDB {
      if model.database == nil {
        model.selectDatabase(row.name)
      } else if model.store == nil {
        model.selectStore(row.name)
      }
    } else if model.area == .cache {
      if model.cacheID == nil {
        model.selectCache(row.id)
      } else if model.cacheEntryURL == nil {
        model.selectCacheEntry(row.name)
      }
    }
  }

  private func beginEdit(_ row: ShaarApplicationRow?) {
    editorKey = row?.name ?? ""
    editorValue = row?.value ?? ""
    editing = true
  }

  private func perform(_ action: Confirmation?) async {
    guard let action else { return }
    do {
      switch action {
      case .removeStorage(let key): await model.removeStorage(key: key)
      case .clearStorage: await model.clearStorage()
      case .clearCookies: try await clearCookies?()
      case .clearSiteData: try await clearSiteData?()
      case .unregisterWorker(let id):
        if let worker = model.workers.first(where: { $0.id == id }) {
          await model.unregisterWorker(worker)
        }
      }
      if action == .clearSiteData || action == .clearCookies { await model.refresh() }
    } catch { model.failure = error.localizedDescription }
  }
}

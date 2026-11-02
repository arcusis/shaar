// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct InspectorStorageView: View {
  @Bindable var model: InspectorPageToolsModel
  @State private var selected: String?
  @State private var key = ""
  @State private var value = ""
  @State private var cookie: InspectorPageToolsModel.Cookie?
  @State private var editing = false
  @State private var reading = false
  @State private var error: String?
  @State private var document = -1

  var body: some View {
    VStack(spacing: 0) {
      Picker("Storage area", selection: $model.storageArea) {
        Text("Local").tag("local")
        Text("Session").tag("session")
        Text("Cookies").tag("cookies")
      }.pickerStyle(.segmented).labelsHidden().controlSize(.small).padding(12)
      HStack {
        Text(
          model.storageArea == "cookies"
            ? "\(model.cookies.count) cookies for this URL"
            : "\(model.storage.count) keys · current origin"
        )
        .font(.system(size: 11)).foregroundStyle(.secondary)
        Spacer()
        InspectorIconButton("Refresh storage", symbol: "arrow.clockwise") { refresh() }
        InspectorIconButton("Add entry", symbol: "plus") {
          reset()
          document = model.inspector?.documentGeneration ?? -1
          editing = true
        }
      }.padding(.horizontal, 12).padding(.bottom, 10)
      Divider()
      ScrollView {
        LazyVStack(spacing: 0) {
          if model.storageArea == "cookies" {
            ForEach(model.cookies) { cookie in
              entry(
                cookie.name, preview: cookie.value,
                detail: cookie.domain + cookie.path
                  + (cookie.raw["httpOnly"] as? Bool == true ? " · HttpOnly" : ""), id: cookie.id
              ) {
                reset()
                document = model.inspector?.documentGeneration ?? -1
                self.cookie = cookie
                selected = cookie.id
                key = cookie.name
                value = cookie.value
                editing = true
              }
            }
          } else {
            ForEach(model.storage) { row in
              entry(row.key, preview: row.preview, detail: "\(row.length) characters", id: row.id) {
                select(row)
              }
            }
          }
          if model.storageLimited {
            Text(
              model.storageArea == "cookies"
                ? "Showing up to 200 cookies." : "Showing up to 200 keys; oversized keys omitted."
            ).font(.system(size: 11))
              .foregroundStyle(.secondary).padding(12)
          }
        }
      }.frame(maxHeight: editing ? 200 : .infinity)
      if editing {
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 9) {
            Text(selected == nil ? "New entry" : "Edit value").font(
              .system(size: 11, weight: .semibold))
            TextField("Key", text: $key).textFieldStyle(.roundedBorder).disabled(selected != nil)
            TextEditor(text: $value).font(.system(size: 11, design: .monospaced))
              .frame(height: 120).border(.secondary.opacity(0.2))
            if let cookie {
              Text(
                cookie.editable
                  ? "Domain, path, expiry, partition and security flags are preserved."
                  : "Opaque partition cookie · read only"
              )
              .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack {
              if selected != nil {
                Button("Delete", role: .destructive) { save(deleting: true) }.disabled(
                  reading || cookie?.editable == false)
              }
              Spacer()
              Button("Cancel", action: reset)
              Button("Save") { save(deleting: false) }.disabled(
                reading || cookie?.editable == false
                  || (model.storageArea == "cookies" && key.isEmpty))
            }.controlSize(.small).font(.system(size: 11))
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.secondary) }
          }.padding(12)
        }.frame(maxHeight: 340).layoutPriority(1)
      }
    }
    .onChange(of: model.storageArea) { _, _ in
      reset()
      refresh()
    }
    .onChange(of: model.inspector?.documentGeneration) { _, _ in
      reset()
      refresh()
    }
  }

  private func entry(
    _ key: String, preview: String, detail: String, id: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 5) {
        Text(key).font(.system(size: 11, weight: .medium, design: .monospaced)).lineLimit(1)
          .truncationMode(.middle)
        Text(preview).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
          .lineLimit(2)
        Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
          .truncationMode(.middle)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(selected == id ? Color.accentColor.opacity(0.08) : .clear)
        .contentShape(Rectangle()).overlay(alignment: .bottom) { Divider() }
    }.buttonStyle(.plain)
  }

  private func select(_ row: InspectorPageToolsModel.StorageRow) {
    reset()
    document = model.inspector?.documentGeneration ?? -1
    selected = row.id
    key = row.key
    reading = true
    editing = true
    let generation = document
    let area = model.storageArea
    Task {
      do {
        let full = try await model.storageValue(key: row.key)
        guard generation == document, area == model.storageArea, selected == row.id else { return }
        value = full
      } catch { self.error = error.localizedDescription }
      if generation == document, area == model.storageArea, selected == row.id { reading = false }
    }
  }

  private func refresh() {
    Task { do { try await model.loadStorage() } catch { self.error = error.localizedDescription } }
  }

  private func save(deleting: Bool) {
    guard document == model.inspector?.documentGeneration else {
      reset()
      return
    }
    reading = true
    let generation = document
    Task {
      if model.storageArea == "cookies" {
        if deleting, let cookie {
          await model.deleteCookie(cookie)
        } else {
          await model.writeCookie(cookie, name: key, value: value)
        }
      } else {
        await model.writeStorage(key: key, value: deleting ? nil : value)
      }
      guard generation == document else { return }
      reading = false
      if let failure = model.failure { error = failure } else { reset() }
    }
  }

  private func reset() {
    selected = nil
    cookie = nil
    key = ""
    value = ""
    error = nil
    editing = false
    reading = false
    document = -1
  }
}

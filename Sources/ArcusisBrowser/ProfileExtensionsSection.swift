// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI

struct ProfileExtensionsSection: View {
  let model: ExtensionManagerModel?
  let sharedModel: SharedExtensionSettingsModel?
  let onAddExtensions: () -> Void
  @State private var detailID: String?

  var body: some View {
    Group {
      if let model, let item = model.extensions.first(where: { $0.id == detailID }) {
        ExtensionDetails(model: model, item: item) { detailID = nil }
      } else {
        VStack(alignment: .leading, spacing: 0) {
          if let sharedModel {
            SharedExtensionSettingsSection(model: sharedModel)
          } else if let model {
            ExtensionManagerList(
              model: model, canRun: false, run: { _ in }, showDetails: { detailID = $0 }
            )
            .frame(maxHeight: 220)
          } else {
            ContentUnavailableView(
              SettingsL10n.string("No Extensions"), systemImage: "puzzlepiece.extension",
              description: Text(
                SettingsL10n.string("Extensions you add appear here for this profile."))
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
          }
          Button(action: onAddExtensions) {
            Label(SettingsL10n.string("Add Extensions…"), systemImage: "plus")
          }
          .buttonStyle(.link)
          .padding(.top, 8)
          .disabled(model == nil && sharedModel == nil)
        }
        .task {
          model?.refresh()
          await sharedModel?.reload()
        }
      }
    }
  }
}

private struct SharedExtensionSettingsSection: View {
  let model: SharedExtensionSettingsModel

  var body: some View {
    if model.rows.isEmpty {
      ContentUnavailableView(
        SettingsL10n.string("No Extensions"), systemImage: "puzzlepiece.extension",
        description: Text(SettingsL10n.string("Extensions you add appear here for this profile."))
      )
      .padding(.vertical, 12)
    } else {
      VStack(alignment: .leading, spacing: 12) {
        ForEach(model.rows) { row in
          VStack(alignment: .leading, spacing: 6) {
            Text(row.name).font(.headline)
            ForEach(
              row.profiles.keys.sorted(by: {
                (row.profiles[$0]?.name ?? "") < (row.profiles[$1]?.name ?? "")
              }), id: \.self
            ) { profileID in
              if let state = row.profiles[profileID] {
                if let enabled = state.enabled {
                  Toggle(
                    state.name,
                    isOn: Binding(
                      get: { enabled },
                      set: { value in
                        Task {
                          await model.setEnabled(value, extensionID: row.id, profileID: profileID)
                        }
                      }))
                } else if state.failed {
                  HStack {
                    Text(state.name)
                    Spacer()
                    Text(SettingsL10n.string("Install failed"))
                      .foregroundStyle(.secondary)
                    Button(SettingsL10n.string("Retry")) {
                      Task { await model.reconcile(profileID: profileID) }
                    }
                  }
                } else {
                  LabeledContent(state.name, value: statusText(state))
                }
              }
            }
          }
        }
        if let error = model.error { Text(error).foregroundStyle(.red) }
      }
      .padding(.vertical, 8)
    }
  }

  private func statusText(_ state: SharedExtensionProfileState) -> String {
    if state.pending { return SettingsL10n.string("Installing…") }
    if state.failed { return SettingsL10n.string("Install failed") }
    return SettingsL10n.string("Not installed")
  }
}

struct ExtensionManagerList: View {
  let model: ExtensionManagerModel
  let canRun: Bool
  let run: (String) -> Void
  let showDetails: (String) -> Void

  var body: some View {
    if model.extensions.isEmpty {
      ContentUnavailableView(
        SettingsL10n.string("No Extensions"), systemImage: "puzzlepiece.extension",
        description: Text(SettingsL10n.string("Extensions you add appear here for this profile."))
      )
      .padding(.vertical, 12)
    } else {
      ScrollView {
        VStack(spacing: 2) {
          ForEach(model.extensions) { item in
            ExtensionRow(
              item: item, icon: model.icons[item.id],
              pinned: model.pinnedIDs.contains(item.id), canRun: canRun,
              actions: ExtensionRowActions(
                run: { run(item.id) },
                setPinned: { model.setPinned(item.id, pinned: $0) },
                setEnabled: { model.setEnabled(item.id, enabled: $0) },
                showDetails: { showDetails(item.id) }))
          }
        }
        .padding(8)
      }
      .frame(maxHeight: 360)
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct ExtensionDetails: View {
  let model: ExtensionManagerModel
  let item: ManagedExtension
  let back: () -> Void
  @State private var confirmsRemoval = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button(action: back) {
        Label(SettingsL10n.string("Extensions"), systemImage: "chevron.backward")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      HStack(spacing: 12) {
        ExtensionIcon(image: model.icons[item.id], size: 40)
        VStack(alignment: .leading, spacing: 2) {
          Text(item.name).font(.headline).lineLimit(2)
          Text(SettingsL10n.format("Version %@", .string(item.version))).font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      if !item.description.isEmpty {
        Text(item.description).font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      detailSection(SettingsL10n.string("Permissions"), values: item.permissions)
      detailSection(SettingsL10n.string("Site access"), values: item.hostPermissions)
      Divider()
      Button(SettingsL10n.string("Remove Extension…"), role: .destructive) {
        confirmsRemoval = true
      }
      .disabled(!item.mayDisable)
    }
    .padding(16)
    .confirmationDialog(
      SettingsL10n.format("Remove %@?", .string(item.name)), isPresented: $confirmsRemoval,
      titleVisibility: .visible
    ) {
      Button(SettingsL10n.string("Remove"), role: .destructive) {
        model.remove(item.id)
        back()
      }
    } message: {
      Text(
        SettingsL10n.string(
          "Its data in this profile is deleted. You can add it again from the Chrome Web Store."))
    }
  }

  @ViewBuilder
  private func detailSection(_ title: String, values: [String]) -> some View {
    if !values.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        ForEach(values, id: \.self) { value in
          Text(value).font(.caption).lineLimit(1).truncationMode(.middle)
        }
      }
    }
  }
}

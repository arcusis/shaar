// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI

struct ProfileExtensionsSection: View {
  static let extensionRowHeadingTraits: AccessibilityTraits = .isHeader
  let model: ExtensionManagerModel?
  let sharedModel: SharedExtensionSettingsModel?
  let pageOrigin: () -> String?
  let selectedTabID: () -> UUID?
  let onAddExtensions: () -> Void
  let onLoadUnpacked: () -> Void
  @State private var detailID: String?

  init(
    model: ExtensionManagerModel?, sharedModel: SharedExtensionSettingsModel? = nil,
    pageOrigin: @escaping () -> String? = { nil }, selectedTabID: @escaping () -> UUID? = { nil },
    onAddExtensions: @escaping () -> Void, onLoadUnpacked: @escaping () -> Void = {}
  ) {
    self.model = model
    self.sharedModel = sharedModel
    self.pageOrigin = pageOrigin
    self.selectedTabID = selectedTabID
    self.onAddExtensions = onAddExtensions
    self.onLoadUnpacked = onLoadUnpacked
  }

  static func sortedProfileIDs(
    for row: SharedExtensionSettingsRow, language: BrowserLanguage = .currentLaunchLanguage
  ) -> [UUID] {
    let locale = Locale(identifier: language.localeIdentifier)
    return row.profiles.keys.sorted { lhs, rhs in
      let lhsName = row.profiles[lhs]?.name ?? ""
      let rhsName = row.profiles[rhs]?.name ?? ""
      let order = lhsName.compare(
        rhsName, options: [.caseInsensitive, .diacriticInsensitive, .numeric], locale: locale)
      return order == .orderedSame ? lhs.uuidString < rhs.uuidString : order == .orderedAscending
    }
  }

  static func toggleAccessibilityLabel(
    extensionName: String, profileName: String,
    language: BrowserLanguage = .currentLaunchLanguage
  ) -> String {
    BrowserLocalization.format(
      "Extension %@ for profile %@", table: "Settings", language: language,
      arguments: [.string(extensionName), .string(profileName)])
  }

  static func installRetryLabel(
    extensionName: String, profileName: String,
    language: BrowserLanguage = .currentLaunchLanguage
  ) -> String {
    BrowserLocalization.format(
      "Retry installing %@ for %@", table: "Settings", language: language,
      arguments: [.string(extensionName), .string(profileName)])
  }

  var body: some View {
    Group {
      if let model, let item = model.extensions.first(where: { $0.id == detailID }) {
        ExtensionDetails(
          model: model, item: item, pageOrigin: pageOrigin, selectedTabID: selectedTabID
        ) { detailID = nil }
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
          if let model {
            ExtensionDeveloperControls(model: model, onLoadUnpacked: onLoadUnpacked)
          }
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
      if let error = model.error {
        VStack(spacing: 8) {
          ContentUnavailableView(
            SettingsL10n.string("Extensions unavailable"), systemImage: "exclamationmark.triangle",
            description: Text(error)
          )
          Button(SettingsL10n.string("Retry")) { Task { await model.reload() } }
            .accessibilityIdentifier("settings.extensions.reload")
        }
        .padding(.vertical, 12)
      } else {
        ContentUnavailableView(
          SettingsL10n.string("No Extensions"), systemImage: "puzzlepiece.extension",
          description: Text(SettingsL10n.string("Extensions you add appear here for this profile."))
        )
        .padding(.vertical, 12)
      }
    } else {
      VStack(alignment: .leading, spacing: 12) {
        ForEach(model.rows) { row in
          VStack(alignment: .leading, spacing: 6) {
            Text(row.name).font(.headline)
              .accessibilityAddTraits(ProfileExtensionsSection.extensionRowHeadingTraits)
            ForEach(ProfileExtensionsSection.sortedProfileIDs(for: row), id: \.self) { profileID in
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
                      })
                  )
                  .accessibilityLabel(
                    ProfileExtensionsSection.toggleAccessibilityLabel(
                      extensionName: row.name, profileName: state.name))
                } else if state.failed {
                  HStack {
                    Text(state.name)
                    Spacer()
                    Text(SettingsL10n.string("Install failed"))
                      .foregroundStyle(.secondary)
                    Button(SettingsL10n.string("Retry")) {
                      Task { await model.reconcile(profileID: profileID) }
                    }
                    .accessibilityLabel(
                      ProfileExtensionsSection.installRetryLabel(
                        extensionName: row.name, profileName: state.name))
                  }
                } else {
                  LabeledContent(state.name, value: statusText(state))
                }
              }
            }
          }
        }
        if let error = model.error {
          HStack {
            Text(error).foregroundStyle(.red)
            Button(SettingsL10n.string("Retry")) { Task { await model.reload() } }
              .accessibilityIdentifier("settings.extensions.reload")
          }
        }
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
                setEnabled: { enabled in
                  MainActor.assumeIsolated { model.setEnabled(item.id, enabled: enabled) }
                },
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

private struct ExtensionDeveloperControls: View {
  let model: ExtensionManagerModel
  let onLoadUnpacked: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Toggle(
        SettingsL10n.string("Developer mode"),
        isOn: Binding(
          get: { model.developerMode },
          set: { model.setDeveloperMode($0) })
      )
      .toggleStyle(.checkbox)
      .accessibilityIdentifier("settings.extensions.developerMode")
      if model.developerMode {
        Button(SettingsL10n.string("Load unpacked…"), action: onLoadUnpacked)
          .accessibilityIdentifier("settings.extensions.loadUnpacked")
        Text(
          SettingsL10n.string(
            "Load an unpacked Manifest V3 extension from a folder on this Mac.")
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      ExtensionInstallStatus(model: model)
    }
    .padding(.top, 8)
    .accessibilityIdentifier("settings.extensions")
  }
}

private struct ExtensionInstallStatus: View {
  let model: ExtensionManagerModel

  var body: some View {
    if let status = model.status {
      Text(status)
        .font(.caption)
        .foregroundStyle(.red)
        .accessibilityIdentifier("settings.extensions.status")
    }
  }
}

struct ExtensionDetails: View {
  static let detailsHeadingTraits: AccessibilityTraits = .isHeader
  let model: ExtensionManagerModel
  let item: ManagedExtension
  let pageOrigin: () -> String?
  let selectedTabID: () -> UUID?
  let back: () -> Void
  @State private var confirmsRemoval = false

  init(
    model: ExtensionManagerModel, item: ManagedExtension,
    pageOrigin: @escaping () -> String? = { nil },
    selectedTabID: @escaping () -> UUID? = { nil }, back: @escaping () -> Void
  ) {
    self.model = model
    self.item = item
    self.pageOrigin = pageOrigin
    self.selectedTabID = selectedTabID
    self.back = back
  }

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
      Menu {
        if let origin = pageOrigin() {
          Text(origin)
        }
        ForEach(ExtensionSiteAccess.allCases) { access in
          Button(access.title) {
            guard let origin = pageOrigin() else {
              model.setSiteAccess(
                access, extensionID: item.id, origin: "", tabID: selectedTabID())
              return
            }
            model.setSiteAccess(
              access, extensionID: item.id, origin: origin, tabID: selectedTabID())
          }
        }
      } label: {
        Text(
          ExtensionSiteAccess.recognized(item.siteAccess)?.title
            ?? SettingsL10n.string("Site access"))
      }
      .accessibilityIdentifier("settings.extensions.siteAccess")
      Toggle(
        SettingsL10n.string("Allow in private windows"),
        isOn: Binding(
          get: { item.incognitoEnabled == true },
          set: { model.setIncognitoEnabled(item.id, enabled: $0) })
      )
      .toggleStyle(.checkbox)
      .disabled(!item.mayDisable)
      .accessibilityIdentifier("settings.extensions.privateWindows")
      ExtensionInstallStatus(model: model)
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
          .accessibilityAddTraits(Self.detailsHeadingTraits)
        ForEach(values, id: \.self) { value in
          Text(value).font(.caption).lineLimit(1).truncationMode(.middle)
        }
      }
    }
  }
}

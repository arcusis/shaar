// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI

struct ProfilePrivacySections: View {
  @State private var model: ProfilePrivacyModel
  @State private var confirmClear = false
  @State private var clearSiteData = true
  @State private var resettingOrigin: String?
  @State private var expandedSites: Set<String> = []

  init(profileID: UUID, backend: any ProfileSettingsBackend) {
    _model = State(initialValue: ProfilePrivacyModel(profileID: profileID, backend: backend))
  }

  init(model: ProfilePrivacyModel, expandedSites: Set<String> = []) {
    _model = State(initialValue: model)
    _expandedSites = State(initialValue: expandedSites)
  }

  var body: some View {
    Group {
      Section {
        LabeledContent(SettingsL10n.string("Cookies and Site Data")) {
          Button(SettingsL10n.string("Clear Site Data…")) {
            clearSiteData = true
            confirmClear = true
          }
          .accessibilityIdentifier("settings.clearSiteData")
        }
        LabeledContent(SettingsL10n.string("Cached Files")) {
          Button(SettingsL10n.string("Clear Cache…")) {
            clearSiteData = false
            confirmClear = true
          }
          .accessibilityIdentifier("settings.clearCache")
        }
      } header: {
        Text(SettingsL10n.string("Website Data"))
      } footer: {
        Text(
          SettingsL10n.string(
            "Only the selected profile is affected. Clearing site data signs you out of websites. Cache clearing keeps your sign-ins."
          ))
      }
      .task { await model.load() }
      .confirmationDialog(
        SettingsL10n.string(
          clearSiteData ? "Clear site data for this profile?" : "Clear cache for this profile?"),
        isPresented: $confirmClear
      ) {
        Button(
          SettingsL10n.string(clearSiteData ? "Clear Site Data" : "Clear Cache"), role: .destructive
        ) {
          let siteData = clearSiteData
          Task { await model.clear(siteData: siteData) }
        }
      }
      Section {
        if let blocked = model.cookiesBlocked {
          Toggle(
            SettingsL10n.string("Block Third-Party Cookies"),
            isOn: Binding(
              get: { blocked },
              set: { value in Task { await model.setCookiesBlocked(value) } })
          )
          .disabled(model.cookiesManaged)
        } else {
          LabeledContent(
            SettingsL10n.string("Block Third-Party Cookies"),
            value: SettingsL10n.string("Unavailable in this engine"))
        }
      } header: {
        Text(SettingsL10n.string("Cookies"))
      } footer: {
        if model.cookiesManaged {
          Text(SettingsL10n.string("This cookie policy is managed by your organization."))
        } else if model.cookiesBlocked == nil {
          Text(
            SettingsL10n.string(
              "This engine cannot read or change the third-party cookie policy. Your cookie policy has not been changed."
            ))
        }
      }
      Section {
        HStack {
          if let busyMessage = model.busyMessage {
            ProgressView(busyMessage).controlSize(.small)
          }
          Spacer()
          Button(SettingsL10n.string("Refresh")) { Task { await model.load() } }
        }
        if model.loaded && model.sites.isEmpty {
          Text(SettingsL10n.string("No site permission exceptions found."))
            .foregroundStyle(.secondary)
        }
        ForEach(model.sites) { site in
          DisclosureGroup(
            isExpanded: Binding(
              get: { expandedSites.contains(site.id) },
              set: {
                if $0 { expandedSites.insert(site.id) } else { expandedSites.remove(site.id) }
              })
          ) {
            ForEach(site.permissions) { permission in
              LabeledContent(permission.title, value: permission.valueLabel)
            }
            Button(SettingsL10n.string("Reset Permissions…"), role: .destructive) {
              resettingOrigin = site.id
            }
            .accessibilityLabel(BrowserSettingsAccessibility.resetPermissionsLabel(origin: site.id))
          } label: {
            Text(site.id).textSelection(.enabled)
              .environment(\.layoutDirection, .leftToRight)
          }
        }
      } header: {
        Text(SettingsL10n.string("Site Permissions"))
      } footer: {
        Text(
          SettingsL10n.string(
            "Review site exceptions for this profile. Resetting removes saved choices and restores defaults. Wildcard and managed rules are not listed by this engine."
          ))
      }
      .confirmationDialog(
        SettingsL10n.string("Reset this site's permissions?"),
        isPresented: Binding(
          get: { resettingOrigin != nil }, set: { if !$0 { resettingOrigin = nil } })
      ) {
        if let origin = resettingOrigin {
          Button(SettingsL10n.string("Reset Permissions"), role: .destructive) {
            Task { await model.resetPermissions(origin: origin) }
          }
        }
      } message: {
        Text(resettingOrigin ?? "")
      }
      if let failure = model.failure {
        Section { Text(failure).foregroundStyle(.red) }
      }
      if let message = model.message {
        Section { Text(message).foregroundStyle(.secondary) }
      }
    }
    .disabled(model.busy)
  }
}

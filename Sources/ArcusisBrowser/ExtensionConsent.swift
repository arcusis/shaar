// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI

struct ExtensionConsent: View {
  let store: BrowserStore
  let request: ExtensionInstallRequest
  @Environment(\.dismiss) private var dismiss
  @State private var acknowledgedUnknownAccess = false

  private var hasUnknownAccess: Bool {
    request.permissions.contains(ExtensionConsentPermissions.unknownAccess)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Label(
        PanelsL10n.format("%@?", .string(PanelsL10n.string(request.kind.actionTitle))),
        systemImage: "puzzlepiece.extension"
      )
      .font(.title2.weight(.semibold))
      VStack(alignment: .leading, spacing: 5) {
        Text(request.browserExtension.name).font(.headline)
        Text(PanelsL10n.format("Version %@", .string(request.browserExtension.version)))
          .font(.caption).foregroundStyle(
            .secondary)
        Text(request.browserExtension.id).font(.caption.monospaced()).foregroundStyle(.secondary)
          .environment(\.layoutDirection, .leftToRight)
      }
      LabeledContent(PanelsL10n.string("Profile"), value: profileName)
      LabeledContent {
        Text(request.sourceURL.host() ?? request.sourceURL.absoluteString)
          .environment(\.layoutDirection, .leftToRight)
      } label: {
        Text(PanelsL10n.string("Page"))
      }
      Divider()
      Text(PanelsL10n.string("This extension can:")).font(.headline)
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if request.permissions.isEmpty {
            Text(
              PanelsL10n.string(
                "No additional permission warnings were reported by the browser engine."))
          }
          ForEach(Array(request.permissions.enumerated()), id: \.offset) { _, permission in
            Label {
              Text(permission).fixedSize(horizontal: false, vertical: true)
            } icon: {
              Image(systemName: "checkmark.shield")
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(minHeight: 75, maxHeight: 200)
      if hasUnknownAccess {
        VStack(alignment: .leading, spacing: 8) {
          Label(PanelsL10n.string("Unknown access"), systemImage: "exclamationmark.triangle.fill")
            .font(.headline).foregroundStyle(.orange)
          Text(
            PanelsL10n.string(
              "Browser engine did not provide a complete site access list. Extension may access sites not listed above."
            )
          )
          .font(.callout)
          Toggle(
            PanelsL10n.string("I understand and want to continue"),
            isOn: $acknowledgedUnknownAccess
          )
          .font(.callout)
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
      }
      Text(PanelsL10n.format("Applies to all spaces sharing the %@ profile.", .string(profileName)))
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button(PanelsL10n.string("Cancel"), role: .cancel) { resolve(accepted: false) }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button(PanelsL10n.string(request.kind.actionTitle)) { resolve(accepted: true) }
          .disabled(
            !request.matches(store.session) || (hasUnknownAccess && !acknowledgedUnknownAccess))
      }
    }
    .padding(28)
    .frame(width: 460)
    .background(Color(nsColor: .windowBackgroundColor))
    .interactiveDismissDisabled()
    .onChange(of: request.id) { _, _ in acknowledgedUnknownAccess = false }
  }

  private var profileName: String {
    store.session.profiles.first { $0.id == request.profileID }?.name
      ?? PanelsL10n.string("Unavailable profile")
  }

  private func resolve(accepted: Bool) {
    store.resolveInstallation(request.id, accepted: accepted)
    dismiss()
  }
}

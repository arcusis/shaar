// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI

struct ExternalAppConsent: View {
  let store: BrowserStore
  let request: ExternalAppRequest
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Label(PanelsL10n.string("Open in another app?"), systemImage: "app")
          .font(.title2.weight(.semibold))
        Text(request.applicationName ?? PanelsL10n.string("No app available"))
          .font(.headline).fixedSize(horizontal: false, vertical: true)
        LabeledContent(PanelsL10n.string("Website")) {
          Text(request.requestingOrigin?.absoluteString ?? PanelsL10n.string("Unknown website"))
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .environment(\.layoutDirection, .leftToRight)
        }
        LabeledContent(PanelsL10n.string("Profile")) {
          Text(profileName).fixedSize(horizontal: false, vertical: true)
        }
        LabeledContent(PanelsL10n.string("Link type")) {
          Text(request.scheme).fixedSize(horizontal: false, vertical: true)
            .environment(\.layoutDirection, .leftToRight)
        }
        Divider()
        Text(
          PanelsL10n.string(
            request.canOpen
              ? "This will open one link in the selected app. This choice applies once."
              : "No compatible app is installed for this link type.")
        )
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        HStack {
          if request.canOpen {
            Button(PanelsL10n.string("Cancel"), role: .cancel) { resolve(accepted: false) }
              .keyboardShortcut(.cancelAction)
            Spacer()
            Button(PanelsL10n.string("Open Once")) { resolve(accepted: true) }
              .keyboardShortcut(.defaultAction)
              .disabled(!isCurrent)
          } else {
            Spacer()
            Button(PanelsL10n.string("Close")) { resolve(accepted: false) }
              .keyboardShortcut(.defaultAction)
          }
        }
      }
      .padding(28)
    }
    .frame(width: 440)
    .frame(maxHeight: 620)
    .background(Color(nsColor: .windowBackgroundColor))
    .interactiveDismissDisabled()
  }

  private var isCurrent: Bool {
    request.matches(store.session)
      && store.rendererFailures[request.tabID] == nil
      && store.externalAppRequests.contains(request)
  }

  private var profileName: String {
    store.session.profiles.first { $0.id == request.profileID }?.name
      ?? PanelsL10n.string("Unavailable profile")
  }

  private func resolve(accepted: Bool) {
    store.resolveExternalApp(request.id, accepted: accepted)
    dismiss()
  }
}

// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct HTTPAuthSheet: View {
  let store: BrowserStore
  let request: HTTPAuthRequest
  @Environment(\.dismiss) private var dismiss
  @State private var username = ""
  @State private var password = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(PanelsL10n.format("Sign in to %@", .string(request.host)))
        .font(.title2.weight(.semibold))
      Text(
        PanelsL10n.format(
          "%@ is requesting your username and password.", .string(request.host)))
        .foregroundStyle(.secondary)
      if !request.realm.isEmpty {
        LabeledContent(PanelsL10n.string("Realm"), value: request.realm)
          .textSelection(.enabled)
      }
      TextField(PanelsL10n.string("Username"), text: $username)
        .textFieldStyle(.roundedBorder)
        .textContentType(.username)
        .accessibilityIdentifier("http-auth-username")
      SecureField(PanelsL10n.string("Password"), text: $password)
        .textFieldStyle(.roundedBorder)
        .textContentType(.password)
        .accessibilityIdentifier("http-auth-password")
      HStack {
        Button(PanelsL10n.string("Cancel"), role: .cancel) {
          resolve(username: nil, password: nil)
        }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button(PanelsL10n.string("Sign In")) {
          resolve(username: username, password: password)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(username.isEmpty)
      }
    }
    .padding(24)
    .frame(width: 420)
    .background(Color(nsColor: .windowBackgroundColor))
    .interactiveDismissDisabled()
  }

  private func resolve(username: String?, password: String?) {
    store.resolveHTTPAuth(request, username: username, password: password)
    dismiss()
  }
}

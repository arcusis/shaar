// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct JavaScriptDialogSheet: View {
  let request: JavaScriptDialogRequest
  let store: BrowserStore
  @State private var input: String

  init(request: JavaScriptDialogRequest, store: BrowserStore) {
    self.request = request
    self.store = store
    _input = State(initialValue: request.defaultPrompt)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(title).font(.title2.weight(.semibold))
      Text(request.origin).font(.callout).foregroundStyle(.secondary)
      if request.kind != .beforeUnload && !request.message.isEmpty {
        Text(request.message).textSelection(.enabled)
      }
      if request.kind == .prompt {
        TextField("", text: $input).textFieldStyle(.roundedBorder)
      }
      HStack {
        Spacer()
        if request.kind == .alert {
          Button(ShellL10n.string("OK")) { resolve(accepted: true) }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        } else {
          Button(ShellL10n.string("Cancel"), role: .cancel) { resolve(accepted: false) }
            .keyboardShortcut(.cancelAction)
          Button(affirmativeTitle) { resolve(accepted: true) }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
      }
    }
    .padding(24)
    .frame(width: 420)
  }

  private var title: String {
    request.kind == .beforeUnload
      ? ShellL10n.string("Leave this page?")
      : ShellL10n.string("This page says")
  }

  private var affirmativeTitle: String {
    request.kind == .beforeUnload
      ? ShellL10n.string("Leave") : ShellL10n.string("OK")
  }

  private func resolve(accepted: Bool) {
    store.resolveJavaScriptDialog(
      request.id, accepted: accepted,
      input: request.kind == .prompt && accepted ? input : nil)
  }
}

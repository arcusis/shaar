// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Presentation bindings and actions can outlive their hosting view. They must not own private state.
struct PrivateHTTPWarning: ViewModifier {
  weak var store: PrivateBrowserStore?

  private var hostForLocalization: String {
    "\u{2066}\(store?.pendingHTTP?.host() ?? ShellL10n.string("this site"))\u{2069}"
  }

  var isPresented: Binding<Bool> {
    Binding(
      get: { store?.pendingHTTP != nil },
      set: { if !$0 { store?.cancelHTTP() } })
  }

  func body(content: Content) -> some View {
    content.alert(
      ShellL10n.text("This connection would use HTTP"), isPresented: isPresented
    ) {
      Button(ShellL10n.string("Try HTTPS")) { confirm(useHTTPS: true) }
      Button(ShellL10n.string("Continue with HTTP"), role: .destructive) {
        confirm(useHTTPS: false)
      }
      Button(ShellL10n.string("Cancel"), role: .cancel) { cancel() }
    } message: {
      Text(
        ShellL10n.format(
          "HTTP does not encrypt your connection to %1$@. This warning covers addresses opened here. The engine cannot enforce HTTPS across page links and redirects.",
          arguments: [
            .string(hostForLocalization)
          ]))
    }
  }

  func confirm(useHTTPS: Bool) { store?.confirmHTTP(useHTTPS: useHTTPS) }
  func cancel() { store?.cancelHTTP() }
}

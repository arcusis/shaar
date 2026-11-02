// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Presentation bindings and actions can outlive their hosting view. They must not own private state.
struct PrivateHTTPWarning: ViewModifier {
  weak var store: PrivateBrowserStore?

  var isPresented: Binding<Bool> {
    Binding(
      get: { store?.pendingHTTP != nil },
      set: { if !$0 { store?.cancelHTTP() } })
  }

  func body(content: Content) -> some View {
    content.alert("This connection would use HTTP", isPresented: isPresented) {
      Button("Try HTTPS") { confirm(useHTTPS: true) }
      Button("Continue with HTTP", role: .destructive) { confirm(useHTTPS: false) }
      Button("Cancel", role: .cancel) { cancel() }
    } message: {
      Text(
        "HTTP does not encrypt your connection to \(store?.pendingHTTP?.host() ?? "this site"). This warning covers addresses opened here. The engine cannot enforce HTTPS across page links and redirects."
      )
    }
  }

  func confirm(useHTTPS: Bool) { store?.confirmHTTP(useHTTPS: useHTTPS) }
  func cancel() { store?.cancelHTTP() }
}

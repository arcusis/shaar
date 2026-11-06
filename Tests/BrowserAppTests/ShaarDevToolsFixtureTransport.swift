// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

@testable import ArcusisBrowser

struct ShaarDevToolsFixtureTransport: ShaarDevToolsEventTransport {
  let fixture: [ShaarDevToolsEvent]
  var revokeAfterEvents = false

  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarDevToolsTransportMessage> {
    AsyncStream { continuation in
      for event in fixture { continuation.yield(.event(event)) }
      continuation.yield(.streamAvailable)
      for event in fixture { continuation.yield(.event(event)) }
      if revokeAfterEvents { continuation.yield(.streamUnavailable) }
      continuation.finish()
    }
  }
}

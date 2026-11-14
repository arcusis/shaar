// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite
struct MediaSessionTests {
  @Test func payloadMapsEveryStandardActionToItsMediaSessionName() throws {
    let names = [
      "play", "pause", "previoustrack", "nexttrack", "seekbackward", "seekforward", "seekto",
    ]
    let state = try #require(
      MediaSessionState(payload: ["playbackState": "playing", "actions": names]))

    #expect(state.actions == Set(MediaSessionAction.allCases))
    #expect(MediaSessionAction.allCases.map(\.rawValue) == names)
  }
}

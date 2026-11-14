// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserEngineLibraryMutationTests {
  @Test func bookmarkWriteFailureUsesLocalizedLibraryNotice() throws {
    let store = BrowserStore()
    let runtime = LibraryMutationFailureRuntime()
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: runtime),
      windowID: "library-mutation-failure-window", store: store)
    defer { engine.suspensionTask?.cancel() }
    let profile = store.session.selectedSpace.profileID
    var succeeded: Bool?

    let accepted = store.library.mutate(.bookmark(["op": "remove"]), profile: profile) {
      succeeded = $0
    }

    #expect(accepted)
    #expect(succeeded == false)
    #expect(
      store.library.notice(profile, section: .bookmarks)
        == PanelsL10n.string("Could not update the Library. Try again."))
  }
}

@MainActor
private final class LibraryMutationFailureRuntime: ARCChromiumRuntime {
  override func bookmarks(
    forProfileID profileID: String,
    completion: @escaping @MainActor @Sendable ([AnyHashable: Any]?, Error?) -> Void
  ) {
    completion([:], nil)
  }

  override func applyBookmarkOperation(
    _ operation: [AnyHashable: Any], profileID: String,
    completion: @escaping @MainActor @Sendable (Error?) -> Void
  ) {
    completion(
      NSError(
        domain: "LibraryMutationFailureTest", code: 9,
        userInfo: [NSLocalizedDescriptionKey: "Raw bookmark storage error."]))
  }
}

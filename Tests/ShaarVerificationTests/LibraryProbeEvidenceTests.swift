// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser
@testable import ShaarVerification

@Suite struct LibraryProbeEvidenceTests {
  @MainActor @Test func nativeRemovalOpensTheLibraryBeforeDeletingTheFolder() {
    let store = BrowserStore()
    let profile = store.session.selectedSpace.profileID
    let folderID = UUID()
    store.library.onLoad = { _, _, done in
      done(.success([
        "bar": [
          "id": "00000000-0000-4000-8000-000000000001", "k": "f", "t": "Bookmarks bar",
          "c": [["id": folderID.uuidString, "k": "f", "t": "Temporary", "c": []]],
        ],
        "other": [
          "id": "00000000-0000-4000-8000-000000000002", "k": "f", "t": "Other bookmarks",
          "c": [],
        ],
      ]))
    }
    store.library.refresh(profile, section: .bookmarks)
    store.library.onMutation = { _, _, done in done(nil as String?) }

    #expect(LibraryProbeEvidence.deleteBookmarkFromLibrary(folderID, profileID: profile, store: store))
  }

  @Test func acceptsOnlyAuthoredFixtureObjects() throws {
    let document = try #require(
      LibraryProbeEvidence.fixtureDocument("{\"fixture\":\"v1\",\"cookie\":\"account=alpha\"}"))
    #expect(document["cookie"] as? String == "account=alpha")
  }

  @Test func rejectsMissingMalformedAndNonFixturePayloads() {
    for json in [nil, "{", "[]", "{}", "{\"fixture\":\"v2\"}", "{\"fixture\":1}"] {
      #expect(LibraryProbeEvidence.fixtureDocument(json) == nil)
    }
  }

  @Test func identityCheckpointRequiresDistinctSpaceFolderAndBookmarkIDs() {
    let ids = (0..<6).map { _ in UUID() }
    #expect(LibraryProbeEvidence.hasDistinctIdentityIDs(ids))
    #expect(!LibraryProbeEvidence.hasDistinctIdentityIDs([ids[0], ids[0], ids[2]]))
    #expect(LibraryProbeEvidence.hasDistinctIdentityIDs([]))
  }
}

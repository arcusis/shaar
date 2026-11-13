// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct FolderEditorTests {
  @Test func routesRequireExistingFolderAndParentInTheirOriginalSpace() throws {
    let store = BrowserStore()
    let spaceID = store.session.selectedSpaceID
    let folderID = try #require(store.createFolder(name: "Projects", in: spaceID))
    let edit = FolderEditorRoute.edit(spaceID: spaceID, folderID: folderID)
    let createInside = FolderEditorRoute.create(spaceID: spaceID, parentID: folderID)

    #expect(edit.matches(store.session))
    #expect(createInside.matches(store.session))
    #expect(!FolderEditorRoute.edit(spaceID: UUID(), folderID: folderID).matches(store.session))

    #expect(store.removeFolder(folderID, in: spaceID))
    #expect(!edit.matches(store.session))
    #expect(!createInside.matches(store.session))
  }
}

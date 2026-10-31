// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Local identity-only payloads; another app or browser launch cannot move these tabs.
enum SidebarTransfer: Codable, Transferable {
  case tab(sessionID: UUID, sourceSpaceID: UUID, tabID: UUID)
  case space(sessionID: UUID, spaceID: UUID)
  case folder(sessionID: UUID, sourceSpaceID: UUID, folderID: UUID)

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(
      contentType: .init(exportedAs: "com.arcusis.browser.sidebar-item", conformingTo: .data)
    )
    .visibility(.ownProcess)
  }
}

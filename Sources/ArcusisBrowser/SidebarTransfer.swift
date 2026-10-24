import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Local identity-only payloads; another app or browser launch cannot move these tabs.
enum SidebarTransfer: Codable, Transferable {
  case tab(sessionID: UUID, sourceSpaceID: UUID, tabID: UUID)
  case space(sessionID: UUID, spaceID: UUID)

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(
      contentType: .init(exportedAs: "com.arcusis.browser.sidebar-item", conformingTo: .data)
    )
    .visibility(.ownProcess)
  }
}

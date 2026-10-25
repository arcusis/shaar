import BrowserCore
import Foundation

/// A find query belongs to one selected document and is never saved in the session.
struct PageFindState: Identifiable {
  let id = UUID()
  let profileID: UUID
  let tabID: UUID
  let pageURL: URL
  var focusRequest = UUID()
  var requestID = UUID()
  var query = ""
  var matchCount: Int?
  var activeMatch = 0
  var searching = false
  var unavailable = false

  var canMove: Bool { !query.isEmpty && (matchCount ?? 0) > 0 && !searching && !unavailable }

  var status: String {
    if query.isEmpty { return "" }
    if unavailable { return "Page unavailable" }
    guard let count = matchCount else { return "Searching…" }
    if count == 0 { return searching ? "Searching…" : "No matches" }
    if activeMatch > 0 { return "\(activeMatch) of \(count)" }
    return count == 1 ? "1 match" : "\(count) matches"
  }

  func matches(_ session: BrowserSession) -> Bool {
    session.selectedSpace.profileID == profileID
      && session.selectedPage?.tab.id == tabID
      && session.selectedPage?.tab.url == pageURL
      && session.profileID(forTabID: tabID) == profileID
  }
}

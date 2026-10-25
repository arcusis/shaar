import BrowserCore
import Foundation

/// Transient state for a failed document. The live tab and its profile stay owned by Chromium.
struct RendererFailure: Identifiable, Equatable {
  let id = UUID()
  let profileID: UUID
  let tabID: UUID
  let pageURL: URL
  let status: String
  let exitCode: Int
  var reloading = false
  var loadingStarted = false

  var message: String {
    if status == "oom" || status == "evicted" {
      return "This page ran out of memory. Reload it, or switch to another tab."
    }
    return "Reload this page, or switch to another tab to continue."
  }

  func belongs(to session: BrowserSession) -> Bool {
    session.profileID(forTabID: tabID) == profileID
      && session.page(forTabID: tabID) != nil
  }
}

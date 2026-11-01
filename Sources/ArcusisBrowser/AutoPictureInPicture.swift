// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Opens Chromium's video picture-in-picture window when a page with a playing, audible video
/// leaves the screen, and closes that window when the page returns.
@MainActor
final class AutoPictureInPicture {
  struct Engine {
    /// Asks the page to open picture-in-picture for its playing video.
    var enter: (UUID) -> Void
    var exit: (UUID) -> Void
    /// Chromium opens its own automatic picture-in-picture for this page.
    var handlesAutomatically: (UUID) -> Bool
  }

  private let engine: Engine
  /// Pages with an open picture-in-picture window, as reported by the engine.
  private(set) var openPages: Set<UUID> = []
  /// Pages whose window opened, or is opening, because they left the screen.
  private var automaticPages: Set<UUID> = []
  private var visiblePages: Set<UUID> = []

  init(engine: Engine) {
    self.engine = engine
  }

  /// Called with the pages on screen after every selection change.
  func visiblePagesChanged(
    to visible: Set<UUID>, sessions: [UUID: MediaSessionState], allowed: (UUID) -> Bool
  ) {
    let hidden = visiblePages.subtracting(visible)
    let shown = visible.subtracting(visiblePages)
    visiblePages = visible
    // A window still opening stays tracked so it closes when it arrives.
    for page in shown where automaticPages.contains(page) && openPages.contains(page) {
      automaticPages.remove(page)
      engine.exit(page)
    }
    for page in hidden {
      automaticPages.remove(page)
      guard shouldOpen(page, state: sessions[page], allowed: allowed) else { continue }
      automaticPages.insert(page)
      if !engine.handlesAutomatically(page) { engine.enter(page) }
    }
  }

  func pictureInPictureChanged(_ page: UUID, active: Bool) {
    if active {
      openPages.insert(page)
      // The window opened after the page came back on screen.
      if automaticPages.contains(page) && visiblePages.contains(page) {
        automaticPages.remove(page)
        engine.exit(page)
      }
    } else {
      openPages.remove(page)
      automaticPages.remove(page)
    }
  }

  func forget(_ page: UUID) {
    openPages.remove(page)
    automaticPages.remove(page)
    visiblePages.remove(page)
  }

  func forgetAll() {
    openPages.removeAll()
    automaticPages.removeAll()
    visiblePages.removeAll()
  }

  private func shouldOpen(
    _ page: UUID, state: MediaSessionState?, allowed: (UUID) -> Bool
  ) -> Bool {
    guard let state, state.isPlaying, state.hasVideo, !state.silent,
      !openPages.contains(page)
    else { return false }
    return allowed(page)
  }
}

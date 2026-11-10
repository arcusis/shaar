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
  private var mediaSessions: [UUID: MediaSessionState] = [:]

  init(engine: Engine) {
    self.engine = engine
  }

  /// Called with the pages on screen after every selection change.
  func visiblePagesChanged(
    to visible: Set<UUID>, sessions: [UUID: MediaSessionState], allowed: (UUID) -> Bool
  ) {
    let updated = Set(sessions.keys.filter { mediaSessions[$0] != sessions[$0] })
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
    let updatedHidden = updated.subtracting(visible).subtracting(hidden)
    for page in updatedHidden where !automaticPages.contains(page) {
      guard shouldOpen(page, state: sessions[page], allowed: allowed) else { continue }
      automaticPages.insert(page)
      if !engine.handlesAutomatically(page) { engine.enter(page) }
    }
    mediaSessions = sessions
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
    mediaSessions[page] = nil
  }

  func forgetAll() {
    openPages.removeAll()
    automaticPages.removeAll()
    visiblePages.removeAll()
    mediaSessions.removeAll()
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

/// Holds tab activation until picture-in-picture enter replies, without pumping the run loop.
/// The reply or a 300 millisecond fallback runs activation once. A newer switch drops that work.
/// The engine may answer off the main thread; the lock covers the reply.
final class PictureInPictureEnterGate: @unchecked Sendable {
  private let lock = NSLock()
  private var nextSwitch = 0
  private var openSwitch: Int?
  private var pendingBySwitch: [Int: Int] = [:]
  private var armed: ArmedSwitch?

  /// Enters requested after this belong to the switch being reconciled.
  /// An activation still waiting from the previous switch is dropped.
  func startSwitch() {
    lock.lock()
    openSwitch = nil
    pendingBySwitch.removeAll()
    disarmLocked()
    lock.unlock()
  }

  /// One picture-in-picture enter posted for the current switch.
  func begin() -> Int {
    lock.lock()
    defer { lock.unlock() }
    let switchID: Int
    if let openSwitch {
      switchID = openSwitch
    } else {
      switchID = nextSwitch
      nextSwitch += 1
      openSwitch = switchID
    }
    pendingBySwitch[switchID, default: 0] += 1
    return switchID
  }

  func end(generation started: Int) {
    let ready = lock.withLock { () -> Bool in
      guard let count = pendingBySwitch[started], count > 0 else { return false }
      let remaining = count - 1
      if remaining == 0 {
        pendingBySwitch[started] = nil
        return armed?.switchID == started
      }
      pendingBySwitch[started] = remaining
      return false
    }
    if ready { fireIfCurrent(started) }
  }

  /// Runs `perform` from the enter reply or the timeout, whichever comes first.
  /// Returns false when this switch requested nothing, so the caller activates immediately.
  @MainActor
  func deferActivationIfRequested(
    timeout: TimeInterval = 0.3,
    perform: @escaping @MainActor () -> Void
  ) -> Bool {
    let action = MainActorOnce(perform)
    return arm(timeout: timeout) { action.run() }
  }

  private func arm(timeout: TimeInterval, perform: @escaping @Sendable () -> Void) -> Bool {
    lock.lock()
    let requested = openSwitch
    openSwitch = nil
    guard let switchID = requested, (pendingBySwitch[switchID] ?? 0) > 0 else {
      disarmLocked()
      lock.unlock()
      return false
    }
    disarmLocked()
    let item = DispatchWorkItem { [weak self] in
      self?.fireIfCurrent(switchID)
    }
    armed = ArmedSwitch(switchID: switchID, timeout: item, perform: perform)
    lock.unlock()
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
    return true
  }

  private func fireIfCurrent(_ switchID: Int) {
    if Thread.isMainThread {
      runIfCurrent(switchID)
      return
    }
    DispatchQueue.main.async { [self] in
      self.runIfCurrent(switchID)
    }
  }

  private func runIfCurrent(_ switchID: Int) {
    let perform = lock.withLock { takePerformLocked(switchID) }
    perform?()
  }

  /// Caller holds `lock`.
  private func takePerformLocked(_ switchID: Int) -> (@Sendable () -> Void)? {
    guard let armed, armed.switchID == switchID else { return nil }
    disarmLocked()
    return armed.perform
  }

  /// Caller holds `lock`. Drops the waiting activation without running it.
  private func disarmLocked() {
    guard let armed else { return }
    armed.timeout.cancel()
    pendingBySwitch[armed.switchID] = nil
    self.armed = nil
  }
}

private struct ArmedSwitch {
  let switchID: Int
  let timeout: DispatchWorkItem
  let perform: @Sendable () -> Void
}

/// Runs a main-actor activation once. The enter reply may arrive off the main thread.
private final class MainActorOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var perform: (@MainActor () -> Void)?

  @MainActor
  init(_ perform: @escaping @MainActor () -> Void) {
    self.perform = perform
  }

  func run() {
    let perform: (@MainActor () -> Void)? = lock.withLock {
      let perform = self.perform
      self.perform = nil
      return perform
    }
    guard let perform else { return }
    dispatchPrecondition(condition: .onQueue(.main))
    MainActor.assumeIsolated(perform)
  }
}

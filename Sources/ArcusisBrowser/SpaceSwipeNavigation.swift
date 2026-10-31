import AppKit
import SwiftUI

struct SpaceSwipeNavigation: NSViewRepresentable {
  let store: BrowserStore
  let pager: SpacePagerState

  func makeNSView(context: Context) -> SpaceSwipeMonitorView {
    let view = SpaceSwipeMonitorView()
    view.store = store
    view.pager = pager
    return view
  }

  func updateNSView(_ view: SpaceSwipeMonitorView, context: Context) {
    view.store = store
    view.pager = pager
  }

  static func dismantleNSView(_ view: SpaceSwipeMonitorView, coordinator: ()) {
    view.detachFromWindow()
  }
}

@MainActor
final class SpaceSwipeMonitorView: NSView {
  weak var store: BrowserStore?
  weak var pager: SpacePagerState?
  private var owner: SpaceSwipeWindowMonitor?
  private var ownerWindowID: ObjectIdentifier?

  isolated deinit {
    detachFromWindow()
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if window !== newWindow { detachFromWindow() }
    super.viewWillMove(toWindow: newWindow)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window, let store else { return }
    let id = ObjectIdentifier(window)
    let windowOwner = SpaceSwipeWindowMonitor.owner(for: window)
    owner = windowOwner
    ownerWindowID = id
    windowOwner.attach(self, store: store)
  }

  func detachFromWindow() {
    guard ownerWindowID != nil else { return }
    owner?.detach(self)
    self.owner = nil
    self.ownerWindowID = nil
  }
}

@MainActor
final class SpaceSwipeWindowMonitor {
  private final class WeakOwner {
    let identity: ObjectIdentifier
    weak var value: SpaceSwipeWindowMonitor?

    init(_ value: SpaceSwipeWindowMonitor) {
      identity = ObjectIdentifier(value)
      self.value = value
    }
  }

  private static var owners: [ObjectIdentifier: WeakOwner] = [:]

  private weak var window: NSWindow?
  private let windowID: ObjectIdentifier
  private weak var store: BrowserStore?
  private weak var clientView: SpaceSwipeMonitorView?
  private var tracking = false
  private var gestureActive = false
  private var consumeMomentum = false
  private var rejected = false
  private var monitor: Any?
  private var closeObserver: NSObjectProtocol?
  private lazy var ownership = SpaceSwipeMonitorOwnership(
    install: { [weak self] in self?.installMonitor() },
    remove: { [weak self] in self?.removeMonitor() }
  )

  private init(window: NSWindow) {
    self.window = window
    windowID = ObjectIdentifier(window)
    closeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { [weak self, weak window] _ in
      MainActor.assumeIsolated {
        guard let window else { return }
        Self.windowDidClose(window)
        self?.ownership.invalidate()
      }
    }
  }

  isolated deinit {
    removeMonitor()
    Self.removeOwner(self)
  }

  static func owner(for window: NSWindow) -> SpaceSwipeWindowMonitor {
    let id = ObjectIdentifier(window)
    if let owner = owners[id]?.value, owner.window === window { return owner }
    let owner = SpaceSwipeWindowMonitor(window: window)
    owners[id] = WeakOwner(owner)
    return owner
  }

  private static func windowDidClose(_ window: NSWindow) {
    let id = ObjectIdentifier(window)
    guard let owner = owners.removeValue(forKey: id)?.value else { return }
    owner.removeMonitor()
  }

  private static func removeOwner(_ owner: SpaceSwipeWindowMonitor) {
    guard owners[owner.windowID]?.identity == ObjectIdentifier(owner) else { return }
    owners.removeValue(forKey: owner.windowID)
  }

  func attach(_ client: AnyObject, store: BrowserStore) {
    self.store = store
    clientView = client as? SpaceSwipeMonitorView
    ownership.attach(client)
  }

  func detach(_ client: AnyObject) {
    ownership.detach(client)
    if !ownership.hasClients { Self.removeOwner(self) }
  }

  private func installMonitor() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      guard let self else { return event }
      return self.route(event)
    }
  }

  private func removeMonitor() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    closeObserver = nil
  }

  func route(_ event: NSEvent) -> NSEvent? {
    guard let store, let window, let view = clientView, let pager = view.pager else { return event }
    let modalOwnsInput =
      store.commandIsOpen || store.sheet != nil || !store.installationRequests.isEmpty
      || !store.websitePermissionRequests.isEmpty || store.libraryDrawerSection != nil
      || window.attachedSheet != nil || NSApp.modalWindow != nil
    guard event.window === window, !modalOwnsInput, !event.modifierFlags.contains(.command) else {
      if tracking { pager.finish(store: store, cancelled: true) }
      tracking = false
      gestureActive = false
      rejected = true
      return event
    }
    if event.phase.contains(.began) {
      tracking = false
      gestureActive = true
      consumeMomentum = false
      rejected =
        !event.hasPreciseScrollingDeltas
        || !view.bounds.contains(view.convert(event.locationInWindow, from: nil))
      pager.begin()
    }
    if !event.momentumPhase.isEmpty {
      let consumed = consumeMomentum
      if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
        consumeMomentum = false
      }
      return consumed ? nil : event
    }
    if event.phase.contains(.cancelled) || event.phase.contains(.ended) {
      gestureActive = false
      guard tracking else {
        rejected = false
        return event
      }
      pager.finish(store: store, cancelled: event.phase.contains(.cancelled))
      tracking = false
      consumeMomentum = true
      rejected = false
      return nil
    }
    guard gestureActive, !rejected, !event.phase.isEmpty else { return event }
    if !tracking {
      guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), event.scrollingDeltaX != 0
      else {
        if event.scrollingDeltaY != 0 { rejected = true }
        return event
      }
      tracking = true
    }
    let index =
      store.session.spaces.firstIndex(where: { $0.id == store.session.selectedSpaceID }) ?? 0
    pager.move(
      delta: event.scrollingDeltaX, timestamp: event.timestamp, index: index,
      count: store.session.spaces.count)
    return nil
  }

  func route(_ event: NSEvent, deltaX: CGFloat, deltaY: CGFloat) -> NSEvent? {
    guard let store, let window else { return event }
    let modalOwnsInput =
      store.commandIsOpen || store.sheet != nil || !store.installationRequests.isEmpty
      || !store.websitePermissionRequests.isEmpty || store.libraryDrawerSection != nil
      || window.attachedSheet != nil
      || NSApp.modalWindow != nil
    let result = SpaceSwipeNavigationDecision.route(
      deltaX: deltaX,
      deltaY: deltaY,
      eventBelongsToWindow: event.window === window,
      commandPressed: event.modifierFlags.contains(.command),
      modalOwnsInput: modalOwnsInput
    ) { offset in
      store.cycleSpace(by: offset)
    }
    return result == .consumed ? nil : event
  }
}

@MainActor
final class SpaceSwipeMonitorOwnership {
  private let install: () -> Void
  private let remove: () -> Void
  private final class WeakClient {
    weak var value: AnyObject?

    init(_ value: AnyObject) {
      self.value = value
    }
  }

  private var clients: [ObjectIdentifier: WeakClient] = [:]
  private var isInstalled = false

  var hasClients: Bool {
    removeDestroyedClients()
    return !clients.isEmpty
  }

  init(install: @escaping () -> Void, remove: @escaping () -> Void) {
    self.install = install
    self.remove = remove
  }

  func attach(_ client: AnyObject) {
    removeDestroyedClients()
    let wasEmpty = clients.isEmpty
    clients[ObjectIdentifier(client)] = WeakClient(client)
    if wasEmpty, !isInstalled {
      install()
      isInstalled = true
    }
  }

  func detach(_ client: AnyObject) {
    clients.removeValue(forKey: ObjectIdentifier(client))
    if clients.isEmpty { invalidate() }
  }

  private func removeDestroyedClients() {
    clients = clients.filter { $0.value.value != nil }
    if clients.isEmpty { invalidate() }
  }

  func invalidate() {
    clients.removeAll()
    guard isInstalled else { return }
    remove()
    isInstalled = false
  }
}

enum SpaceSwipeRoutingResult: Equatable {
  case consumed
  case forwarded
}

enum SpaceSwipeNavigationDecision {
  static func route(
    deltaX: CGFloat,
    deltaY: CGFloat,
    eventBelongsToWindow: Bool,
    commandPressed: Bool,
    modalOwnsInput: Bool,
    cycleSpace: (Int) -> Void
  ) -> SpaceSwipeRoutingResult {
    guard eventBelongsToWindow, !commandPressed, !modalOwnsInput,
      abs(deltaX) > abs(deltaY), deltaX != 0
    else { return .forwarded }
    cycleSpace(deltaX > 0 ? -1 : 1)
    return .consumed
  }
}

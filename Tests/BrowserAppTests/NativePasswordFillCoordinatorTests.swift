import Foundation
import Synchronization
import Testing

@testable import ArcusisBrowser
@testable import BrowserCore

@MainActor private final class FillFormFixture: PasswordFillForm {
  var reply: ((PasswordFillContext?) -> Void)?
  var fillReply: ((Bool) -> Void)?
  var fills = 0
  var requests = 0
  var onFill: (() -> Void)?
  var onCancel: (() -> Void)?
  func request(completion: @escaping (PasswordFillContext?) -> Void) {
    requests += 1
    reply = completion
  }
  func fill(
    context: PasswordFillContext, username: String, password: String,
    completion: @escaping (Bool) -> Void
  ) {
    fills += 1
    onFill?()
    fillReply = completion
  }
  func cancel() {
    reply = nil
    fillReply = nil
    onCancel?()
  }
}

@MainActor private final class FillVaultFixture: PasswordFillVault {
  let handle: NativeBitwardenController.FillHandle
  var ready = true
  var current = true
  var continuation: CheckedContinuation<NativeBitwardenFillCredential, Error>?
  var checks = 0
  var onCheck: (() -> Void)?
  init(profile: UUID, cipher: UUID) throws {
    var state = NativeBitwardenFillAccessState<Int>(sessionID: UUID())
    let ticket = try state.beginSync()
    let snapshot = try NativeBitwardenVaultSnapshot.make(from: [
      .init(
        id: cipher, name: "Example", username: "person", uris: [], isLogin: true,
        isOrganization: false)
    ])
    try state.publish(ticket: ticket, snapshot: snapshot, items: [cipher: 1])
    handle = .init(
      binding: .init(
        profileID: profile, vaultID: UUID(), accountID: UUID(),
        authority: URL(string: "https://example.com")!), epoch: UUID(), pair: try state.snapshot())
  }
  func fillHandle(profileID: UUID) -> NativeBitwardenController.FillHandle? {
    ready && profileID == handle.binding.profileID ? handle : nil
  }
  func isFillHandleCurrent(_ handle: NativeBitwardenController.FillHandle) -> Bool {
    checks += 1
    onCheck?()
    return current && ready && handle.epoch == self.handle.epoch
      && handle.binding == self.handle.binding
  }
  func fillCredential(
    handle: NativeBitwardenController.FillHandle, cipherID: UUID, context: PasswordFillContext
  ) async throws -> NativeBitwardenFillCredential {
    try await withCheckedThrowingContinuation { continuation = $0 }
  }
  func fail() {
    continuation?.resume(throwing: NativeBitwardenFillError.unsupportedMatch)
    continuation = nil
  }
  func resume() {
    continuation?.resume(returning: .init(username: "person", password: "synthetic secret"))
    continuation = nil
  }
}

private final class FillMemoryItems: PasswordCredentialItemStorage, Sendable {
  private let items = Mutex<[String: Data]>([:])
  func read(service: String, account: String) throws -> Data? {
    items.withLock { $0[service + account] }
  }
  func write(_ data: Data, service: String, account: String) throws {
    items.withLock { $0[service + account] = data }
  }
  func delete(service: String, account: String) throws {
    _ = items.withLock { $0.removeValue(forKey: service + account) }
  }
}

private actor FillControllerBackend: NativeBitwardenBackend, NativeBitwardenFillCredentialBackend {
  let session = UUID()
  let account = UUID()
  let cipher = UUID()
  let foreignSession: Bool
  init(foreignSession: Bool = false) { self.foreignSession = foreignSession }
  var state: NativeBitwardenFillAccessState<Int>?
  var failSync = false
  private var snapshotRead = false
  func didReadSnapshot() -> Bool { snapshotRead }
  func setSyncFailure() { failSync = true }
  var isAvailable: Bool { true }
  func login(
    server: BitwardenServerConfiguration, email: String, password: String, deviceID: UUID,
    secondFactor: NativeBitwardenSecondFactor?
  ) async throws -> NativeBitwardenLoginResult {
    .authenticated(.init(id: session, accountID: account))
  }
  func initializeCrypto(candidateID: UUID, password: String) async throws
    -> NativeBitwardenEstablishedSession
  {
    .init(
      id: session, accountID: account, credential: .init(accessToken: "fixture"),
      tokenProvider: .init())
  }
  func syncVault(sessionID: UUID) async throws -> NativeBitwardenVaultSnapshot {
    if failSync { throw NativeBitwardenBackendError.staleSession }
    let snapshot = try NativeBitwardenVaultSnapshot.make(from: [
      .init(
        id: cipher, name: "Entry", username: "person", uris: [], isLogin: true,
        isOrganization: false)
    ])
    var state = NativeBitwardenFillAccessState<Int>(sessionID: foreignSession ? UUID() : sessionID)
    let ticket = try state.beginSync()
    try state.publish(ticket: ticket, snapshot: snapshot, items: [cipher: 1])
    state.finishSync(ticket)
    self.state = state
    return snapshot
  }
  func fillSnapshot(sessionID: UUID) async throws -> NativeBitwardenFillSnapshotAccess {
    snapshotRead = true
    guard sessionID == session, let state else { throw NativeBitwardenFillError.staleAccess }
    return try state.snapshot()
  }
  func fillCredential(
    access: NativeBitwardenFillAccess, cipherID: UUID, context: PasswordFillContext
  ) async throws -> NativeBitwardenFillCredential {
    guard let state else { throw NativeBitwardenFillError.staleAccess }
    _ = try state.item(access: access, id: cipherID)
    return .init(username: "person", password: "synthetic secret")
  }
  func lock(sessionID: UUID) async -> Bool { true }
  func discard(sessionID: UUID) async {}
}

private actor DeferredDiscardBackend: NativeBitwardenBackend {
  let first = UUID()
  let second = UUID()
  let account = UUID()
  private var loginCount = 0
  private var discarded: CheckedContinuation<Void, Never>?
  private var synced: Set<UUID> = []
  var isAvailable: Bool { true }
  func login(
    server: BitwardenServerConfiguration, email: String, password: String,
    deviceID: UUID, secondFactor: NativeBitwardenSecondFactor?
  ) async throws -> NativeBitwardenLoginResult {
    loginCount += 1
    return .authenticated(.init(id: loginCount == 1 ? first : second, accountID: account))
  }
  func initializeCrypto(candidateID: UUID, password: String) async throws
    -> NativeBitwardenEstablishedSession
  {
    .init(
      id: candidateID, accountID: account, credential: .init(accessToken: "fixture"),
      tokenProvider: .init())
  }
  func syncVault(sessionID: UUID) async throws -> NativeBitwardenVaultSnapshot {
    synced.insert(sessionID)
    return .empty
  }
  func lock(sessionID: UUID) async -> Bool { true }
  func discard(sessionID: UUID) async {
    if sessionID == first { await withCheckedContinuation { discarded = $0 } }
  }
  func discardIsWaiting() -> Bool { discarded != nil }
  func releaseDiscard() {
    discarded?.resume()
    discarded = nil
  }
  func didSync(_ id: UUID) -> Bool { synced.contains(id) }
}

@Suite @MainActor struct NativePasswordFillCoordinatorTests {
  @Test func explicitChoiceAndFinalAuthorization() async throws {
    let owner = PasswordFillBinding(windowID: UUID(), profileID: UUID(), tabID: UUID())
    let cipher = UUID()
    let form = FillFormFixture()
    let vault = try FillVaultFixture(profile: owner.profileID, cipher: cipher)
    let coordinator = NativePasswordFillCoordinator(form: form, vault: vault) { owner }
    coordinator.request()
    let context = PasswordFillContext(
      requestID: UUID(), binding: owner, origin: PasswordFillOrigin("https://example.com")!)
    form.reply?(context)
    #expect(coordinator.entries.count == 1 && coordinator.showingPicker && form.fills == 0)
    #expect(!String(reflecting: coordinator.entries).contains("synthetic secret"))
    coordinator.choose(cipher)
    while vault.continuation == nil { await Task.yield() }
    let before = vault.checks
    form.onFill = { #expect(vault.checks == before + 1) }
    vault.resume()
    while form.fills == 0 { await Task.yield() }
    #expect(form.fills == 1)
    form.fillReply?(true)
    #expect(!coordinator.showingPicker && coordinator.entries.isEmpty)
  }

  @Test func staleLookupAndOwnershipChangesNeverFill() async throws {
    for change in 0..<5 {
      var owner: PasswordFillBinding? = .init(windowID: UUID(), profileID: UUID(), tabID: UUID())
      let initial = owner!
      let cipher = UUID()
      let form = FillFormFixture()
      let vault = try FillVaultFixture(profile: initial.profileID, cipher: cipher)
      var clock: TimeInterval = 0
      let coordinator = NativePasswordFillCoordinator(
        form: form, vault: vault, binding: { owner }, now: { clock })
      coordinator.request()
      form.reply?(
        .init(
          requestID: UUID(), binding: initial, origin: PasswordFillOrigin("https://example.com")!))
      coordinator.choose(cipher)
      while vault.continuation == nil { await Task.yield() }
      switch change {
      case 0: vault.current = false
      case 1: owner = nil
      case 2: owner = .init(windowID: UUID(), profileID: initial.profileID, tabID: initial.tabID)
      case 3: clock = 30
      default: coordinator.cancel()
      }
      vault.resume()
      for _ in 0..<10 { await Task.yield() }
      #expect(form.fills == 0)
      #expect(!coordinator.showingPicker)
    }
  }

  @Test func unavailableAndLateRequest() throws {
    let owner = PasswordFillBinding(windowID: UUID(), profileID: UUID(), tabID: UUID())
    let form = FillFormFixture()
    let vault = try FillVaultFixture(profile: owner.profileID, cipher: UUID())
    let coordinator = NativePasswordFillCoordinator(form: form, vault: vault) { owner }
    vault.ready = false
    coordinator.request()
    #expect(coordinator.message != nil && form.reply == nil)
    vault.ready = true
    coordinator.request()
    let late = form.reply
    coordinator.cancel()
    late?(
      .init(requestID: UUID(), binding: owner, origin: PasswordFillOrigin("https://example.com")!))
    #expect(!coordinator.showingPicker && form.fills == 0)
  }
  @Test func windowsProfilesAndInvalidationStayIndependent() throws {
    let first = PasswordFillBinding(windowID: UUID(), profileID: UUID(), tabID: UUID())
    let second = PasswordFillBinding(windowID: UUID(), profileID: UUID(), tabID: UUID())
    let firstForm = FillFormFixture()
    let secondForm = FillFormFixture()
    let firstVault = try FillVaultFixture(profile: first.profileID, cipher: UUID())
    let secondVault = try FillVaultFixture(profile: second.profileID, cipher: UUID())
    let firstCoordinator = NativePasswordFillCoordinator(form: firstForm, vault: firstVault) {
      first
    }
    let secondCoordinator = NativePasswordFillCoordinator(form: secondForm, vault: secondVault) {
      second
    }
    firstCoordinator.request()
    secondCoordinator.request()
    firstForm.reply?(
      .init(requestID: UUID(), binding: first, origin: PasswordFillOrigin("https://example.com")!))
    secondForm.reply?(
      .init(requestID: UUID(), binding: second, origin: PasswordFillOrigin("https://example.com")!))
    firstCoordinator.vaultDidChange(profileID: first.profileID)
    secondCoordinator.vaultDidChange(profileID: first.profileID)
    #expect(!firstCoordinator.showingPicker && secondCoordinator.showingPicker)
    firstCoordinator.cancel()
    #expect(secondCoordinator.showingPicker)
  }

  @Test func duplicateRequestCallbackDoesNotRestorePicker() throws {
    let owner = PasswordFillBinding(windowID: UUID(), profileID: UUID(), tabID: UUID())
    let cipher = UUID()
    let form = FillFormFixture()
    let vault = try FillVaultFixture(profile: owner.profileID, cipher: cipher)
    let coordinator = NativePasswordFillCoordinator(form: form, vault: vault) { owner }
    coordinator.request()
    let reply = form.reply
    let context = PasswordFillContext(
      requestID: UUID(), binding: owner, origin: PasswordFillOrigin("https://example.com")!)
    reply?(context)
    coordinator.choose(cipher)
    reply?(context)
    #expect(coordinator.busy && form.fills == 0)
    coordinator.cancel()
  }

  @Test func controllerRevokesBeforeLockDisableAndRebind() async throws {
    for action in 0..<4 {
      let profile = UUID()
      let backend = FillControllerBackend()
      let controller = NativeBitwardenController(
        preferences: BrowserPreferencesStore(), backend: backend,
        credentialStore: PasswordCredentialStore(service: "in-memory", storage: FillMemoryItems()))
      controller.selectProfile(profile)
      controller.setEnabled(true)
      controller.email = "fixture@example.test"
      controller.masterPassword = "synthetic"
      controller.connect()
      for _ in 0..<1000 {
        if controller.fillHandle(profileID: profile) != nil { break }
        await Task.yield()
      }
      let handle = try #require(controller.fillHandle(profileID: profile))
      var notifications = 0
      var secondNotifications = 0
      let secondRegistration = controller.observeFillChanges { changed in
        if changed == profile { secondNotifications += 1 }
      }
      var registration: UUID?
      registration = controller.observeFillChanges { changed in
        if changed == profile {
          notifications += 1
          if let registration { controller.removeFillObserver(registration) }
        }
      }
      switch action {
      case 0: controller.lock()
      case 1: controller.setEnabled(false)
      case 2: controller.setServer(.init(region: .eu))
      default: controller.disconnect()
      }
      #expect(notifications == 1 && secondNotifications >= 1)
      controller.removeFillObserver(secondRegistration)
      #expect(!controller.isFillHandleCurrent(handle))
      #expect(controller.fillHandle(profileID: profile) == nil)
      if action == 0 { #expect(controller.hasConnectedSession) }
    }
  }

  @Test func unsupportedPolicyFailsClosed() async throws {
    let owner = PasswordFillBinding(windowID: UUID(), profileID: UUID(), tabID: UUID())
    let cipher = UUID()
    let form = FillFormFixture()
    let vault = try FillVaultFixture(profile: owner.profileID, cipher: cipher)
    let coordinator = NativePasswordFillCoordinator(form: form, vault: vault) { owner }
    coordinator.request()
    form.reply?(
      .init(requestID: UUID(), binding: owner, origin: PasswordFillOrigin("https://example.com")!))
    coordinator.choose(cipher)
    while vault.continuation == nil { await Task.yield() }
    vault.fail()
    for _ in 0..<10 { await Task.yield() }
    #expect(form.fills == 0 && coordinator.message != nil)
    #expect(!String(reflecting: coordinator.message).contains("synthetic secret"))
  }

  @Test func reentrantCancellationDoesNotClobberNewAttempt() throws {
    let owner = PasswordFillBinding(windowID: UUID(), profileID: UUID(), tabID: UUID())
    let form = FillFormFixture()
    let vault = try FillVaultFixture(profile: owner.profileID, cipher: UUID())
    let coordinator = NativePasswordFillCoordinator(form: form, vault: vault) { owner }
    coordinator.request()
    let old = form.reply
    form.onCancel = {
      form.onCancel = nil
      coordinator.request()
    }
    coordinator.cancel()
    let replacement = form.reply
    old?(nil)
    #expect(coordinator.message == nil && replacement != nil)
    replacement?(
      .init(requestID: UUID(), binding: owner, origin: PasswordFillOrigin("https://example.com")!))
    #expect(coordinator.showingPicker)
    coordinator.cancel()
  }

  @Test func accountMismatchRejectsIssuedHandle() async throws {
    let profile = UUID()
    let preferences = BrowserPreferencesStore()
    let controller = NativeBitwardenController(
      preferences: preferences, backend: FillControllerBackend(),
      credentialStore: PasswordCredentialStore(service: "in-memory", storage: FillMemoryItems()))
    controller.selectProfile(profile)
    controller.setEnabled(true)
    controller.email = "fixture@example.test"
    controller.masterPassword = "synthetic"
    controller.connect()
    for _ in 0..<1000 {
      if controller.fillHandle(profileID: profile) != nil { break }
      await Task.yield()
    }
    let handle = try #require(controller.fillHandle(profileID: profile))
    preferences.setNativeVaultAccountID(UUID(), for: profile)
    #expect(!controller.isFillHandleCurrent(handle))
    #expect(controller.fillHandle(profileID: profile) == nil)
  }

  @Test func reconnectRevokesSynchronouslyAndSyncFailureStaysUnavailable() async throws {
    let profile = UUID()
    let backend = FillControllerBackend()
    let controller = NativeBitwardenController(
      preferences: BrowserPreferencesStore(), backend: backend,
      credentialStore: PasswordCredentialStore(service: "in-memory", storage: FillMemoryItems()))
    controller.selectProfile(profile)
    controller.setEnabled(true)
    controller.email = "fixture@example.test"
    controller.masterPassword = "synthetic"
    controller.connect()
    for _ in 0..<1000 {
      if controller.fillHandle(profileID: profile) != nil { break }
      await Task.yield()
    }
    let original = try #require(controller.fillHandle(profileID: profile))
    await backend.setSyncFailure()
    controller.email = "fixture@example.test"
    controller.masterPassword = "synthetic"
    controller.connect()
    #expect(!controller.isFillHandleCurrent(original))
    #expect(controller.fillHandle(profileID: profile) == nil)
    for _ in 0..<1000 {
      if controller.syncStatus.hasPrefix("Sync failed") { break }
      await Task.yield()
    }
    #expect(controller.syncStatus.hasPrefix("Sync failed"))
    #expect(controller.fillHandle(profileID: profile) == nil)
  }

  @Test func awayAndBackCannotReviveCancelledRequest() throws {
    let initial = PasswordFillBinding(windowID: UUID(), profileID: UUID(), tabID: UUID())
    var current = initial
    let form = FillFormFixture()
    let vault = try FillVaultFixture(profile: initial.profileID, cipher: UUID())
    let coordinator = NativePasswordFillCoordinator(form: form, vault: vault) { current }
    coordinator.request()
    let late = form.reply
    current = .init(windowID: initial.windowID, profileID: initial.profileID, tabID: UUID())
    coordinator.cancel()
    current = initial
    late?(
      .init(requestID: UUID(), binding: initial, origin: PasswordFillOrigin("https://example.com")!)
    )
    #expect(!coordinator.showingPicker && form.fills == 0)
  }

  @Test func pairedSnapshotFromForeignSessionIsNeverPublished() async {
    let profile = UUID()
    let backend = FillControllerBackend(foreignSession: true)
    let controller = NativeBitwardenController(
      preferences: BrowserPreferencesStore(), backend: backend,
      credentialStore: PasswordCredentialStore(service: "in-memory", storage: FillMemoryItems()))
    controller.selectProfile(profile)
    controller.setEnabled(true)
    controller.email = "fixture@example.test"
    controller.masterPassword = "synthetic"
    controller.connect()
    for _ in 0..<1000 {
      if await backend.didReadSnapshot() { break }
      await Task.yield()
    }
    #expect(await backend.didReadSnapshot())
    for _ in 0..<20 { await Task.yield() }
    #expect(controller.syncStatus.hasPrefix("Synced"))
    #expect(controller.fillHandle(profileID: profile) == nil)
  }

  @Test func reentrantAuthorizationPreservesReplacementRequest() throws {
    for duringChoice in [false, true] {
      let owner = PasswordFillBinding(windowID: UUID(), profileID: UUID(), tabID: UUID())
      let cipher = UUID()
      let form = FillFormFixture()
      let vault = try FillVaultFixture(profile: owner.profileID, cipher: cipher)
      let coordinator = NativePasswordFillCoordinator(form: form, vault: vault) { owner }
      let context = PasswordFillContext(
        requestID: UUID(), binding: owner, origin: PasswordFillOrigin("https://example.com")!)
      coordinator.request()
      let original = form.reply
      if duringChoice { original?(context) }
      vault.onCheck = {
        vault.onCheck = nil
        coordinator.request()
      }
      if duringChoice { coordinator.choose(cipher) } else { original?(context) }
      #expect(coordinator.message == nil && form.reply != nil)
      form.reply?(context)
      #expect(coordinator.showingPicker && !coordinator.busy && form.fills == 0)
      coordinator.cancel()
    }
  }

  @Test func revokedBeforeScheduledLookupClearsBusyState() async throws {
    let owner = PasswordFillBinding(windowID: UUID(), profileID: UUID(), tabID: UUID())
    let cipher = UUID()
    let form = FillFormFixture()
    let vault = try FillVaultFixture(profile: owner.profileID, cipher: cipher)
    let coordinator = NativePasswordFillCoordinator(form: form, vault: vault) { owner }
    coordinator.request()
    form.reply?(
      .init(requestID: UUID(), binding: owner, origin: PasswordFillOrigin("https://example.com")!))
    coordinator.choose(cipher)
    vault.current = false
    for _ in 0..<20 { await Task.yield() }
    #expect(!coordinator.busy && !coordinator.showingPicker && form.fills == 0)
  }

  @Test func lockDuringPriorDiscardPreventsReplacementSync() async throws {
    let profile = UUID()
    let backend = DeferredDiscardBackend()
    let controller = NativeBitwardenController(
      preferences: BrowserPreferencesStore(), backend: backend,
      credentialStore: PasswordCredentialStore(service: "in-memory", storage: FillMemoryItems()))
    controller.selectProfile(profile)
    controller.setEnabled(true)
    controller.email = "fixture@example.test"
    controller.masterPassword = "synthetic"
    controller.connect()
    for _ in 0..<1000 {
      if controller.syncStatus == "Synced 0 logins" { break }
      await Task.yield()
    }
    #expect(controller.syncStatus == "Synced 0 logins")
    controller.email = "fixture@example.test"
    controller.masterPassword = "synthetic"
    controller.connect()
    for _ in 0..<1000 {
      if await backend.discardIsWaiting() { break }
      await Task.yield()
    }
    #expect(await backend.discardIsWaiting())
    controller.lock()
    await backend.releaseDiscard()
    for _ in 0..<20 { await Task.yield() }
    #expect(!(await backend.didSync(backend.second)))
    #expect(controller.fillHandle(profileID: profile) == nil)
  }

  @Test func reentrantClockCannotOverwriteSuccessorRequest() throws {
    for staleTime in [1.0, Double.infinity] {
      let owner = PasswordFillBinding(windowID: UUID(), profileID: UUID(), tabID: UUID())
      let form = FillFormFixture()
      let vault = try FillVaultFixture(profile: owner.profileID, cipher: UUID())
      var firstClockRead = true
      var coordinator: NativePasswordFillCoordinator!
      coordinator = NativePasswordFillCoordinator(
        form: form, vault: vault, binding: { owner },
        now: {
          if firstClockRead {
            firstClockRead = false
            coordinator.request()
            return staleTime
          }
          return 1
        })
      coordinator.request()
      #expect(form.requests == 1 && coordinator.message == nil)
      let reply = try #require(form.reply)
      reply(
        .init(requestID: UUID(), binding: owner, origin: PasswordFillOrigin("https://example.com")!)
      )
      #expect(coordinator.showingPicker && !coordinator.busy && coordinator.entries.count == 1)
      coordinator.cancel()
    }
  }

  @Test func libraryAndFindCancelSynchronouslyAndMetadataDoesNot() throws {
    let store = BrowserStore()
    let url = URL(string: "https://example.com")!
    store.perform(.open(url))
    let tab = try #require(store.session.selectedPage?.tab.id)
    let owner = PasswordFillBinding(
      windowID: UUID(), profileID: store.session.selectedSpace.profileID, tabID: tab)
    let form = FillFormFixture()
    let vault = try FillVaultFixture(profile: owner.profileID, cipher: UUID())
    let coordinator = NativePasswordFillCoordinator(form: form, vault: vault) {
      BrowserEngine.passwordFillInputAvailable(in: store) ? owner : nil
    }
    let monitor = PasswordFillInputMonitor(store: store) { coordinator.cancel() }
    func request() {
      monitor.arm()
      coordinator.request()
      form.reply?(
        .init(requestID: UUID(), binding: owner, origin: PasswordFillOrigin("https://example.com")!)
      )
    }
    request()
    #expect(coordinator.showingPicker)
    store.nativeTabChanged(tab, url: url, title: "Updated title")
    store.nativePageLoading(tab, loading: false)
    #expect(coordinator.showingPicker)
    let staleLibraryReply = form.reply
    #expect(store.showLibraryDrawer(.spaces))
    #expect(!BrowserEngine.passwordFillInputAvailable(in: store) && !coordinator.showingPicker)
    store.closeLibraryDrawer()
    staleLibraryReply?(
      .init(requestID: UUID(), binding: owner, origin: PasswordFillOrigin("https://example.com")!))
    #expect(!coordinator.showingPicker)
    request()
    #expect(coordinator.showingPicker)
    let staleFindReply = form.reply
    store.showPageFind()
    #expect(store.pageFind != nil && !BrowserEngine.passwordFillInputAvailable(in: store))
    #expect(!coordinator.showingPicker)
    store.dismissPageFind()
    staleFindReply?(
      .init(requestID: UUID(), binding: owner, origin: PasswordFillOrigin("https://example.com")!))
    #expect(!coordinator.showingPicker && form.fills == 0)
    monitor.arm()
    #expect(BrowserEngine.passwordFillInputAvailable(in: store))
  }

  @Test func closingLibraryOrFindCannotRevivePendingLookup() async throws {
    for showFind in [false, true] {
      let store = BrowserStore()
      store.perform(.open(URL(string: "https://example.com")!))
      let tab = try #require(store.session.selectedPage?.tab.id)
      let owner = PasswordFillBinding(
        windowID: UUID(), profileID: store.session.selectedSpace.profileID, tabID: tab)
      let cipher = UUID()
      let form = FillFormFixture()
      let vault = try FillVaultFixture(profile: owner.profileID, cipher: cipher)
      let coordinator = NativePasswordFillCoordinator(form: form, vault: vault) {
        BrowserEngine.passwordFillInputAvailable(in: store) ? owner : nil
      }
      let monitor = PasswordFillInputMonitor(store: store) { coordinator.cancel() }
      monitor.arm()
      coordinator.request()
      form.reply?(
        .init(requestID: UUID(), binding: owner, origin: PasswordFillOrigin("https://example.com")!)
      )
      coordinator.choose(cipher)
      while vault.continuation == nil { await Task.yield() }
      if showFind { store.showPageFind() } else { #expect(store.showLibraryDrawer(.spaces)) }
      #expect(!coordinator.showingPicker && !coordinator.busy)
      if showFind { store.dismissPageFind() } else { store.closeLibraryDrawer() }
      vault.resume()
      for _ in 0..<20 { await Task.yield() }
      #expect(form.fills == 0 && !coordinator.showingPicker)
    }
  }

  @Test func closingCommandOrSheetCannotRevivePendingLookup() async throws {
    for showCommand in [false, true] {
      let store = BrowserStore()
      store.perform(.open(URL(string: "https://example.com")!))
      let tab = try #require(store.session.selectedPage?.tab.id)
      let owner = PasswordFillBinding(
        windowID: UUID(), profileID: store.session.selectedSpace.profileID, tabID: tab)
      let cipher = UUID()
      let form = FillFormFixture()
      let vault = try FillVaultFixture(profile: owner.profileID, cipher: cipher)
      let coordinator = NativePasswordFillCoordinator(form: form, vault: vault) {
        BrowserEngine.passwordFillInputAvailable(in: store) ? owner : nil
      }
      let monitor = PasswordFillInputMonitor(store: store) { coordinator.cancel() }
      monitor.arm()
      coordinator.request()
      form.reply?(
        .init(requestID: UUID(), binding: owner, origin: PasswordFillOrigin("https://example.com")!)
      )
      coordinator.choose(cipher)
      while vault.continuation == nil { await Task.yield() }
      if showCommand {
        store.commandIsOpen = true
      } else {
        store.sheet = .downloads(profileID: owner.profileID)
      }
      #expect(!coordinator.showingPicker && !coordinator.busy)
      if showCommand { store.commandIsOpen = false } else { store.sheet = nil }
      vault.resume()
      for _ in 0..<20 { await Task.yield() }
      #expect(form.fills == 0 && !coordinator.showingPicker)
    }
  }

}

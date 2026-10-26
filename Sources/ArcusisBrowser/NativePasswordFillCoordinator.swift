import BrowserCore
import Foundation
import Observation

@MainActor
protocol PasswordFillForm: AnyObject {
  func request(completion: @escaping (PasswordFillContext?) -> Void)
  func fill(
    context: PasswordFillContext, username: String, password: String,
    completion: @escaping (Bool) -> Void)
  func cancel()
}

extension NativePasswordFormSession: PasswordFillForm {}

@MainActor
protocol PasswordFillVault: AnyObject {
  func fillHandle(profileID: UUID) -> NativeBitwardenController.FillHandle?
  func isFillHandleCurrent(_ handle: NativeBitwardenController.FillHandle) -> Bool
  func fillCredential(
    handle: NativeBitwardenController.FillHandle, cipherID: UUID, context: PasswordFillContext
  ) async throws -> NativeBitwardenFillCredential
}

extension NativeBitwardenController: PasswordFillVault {}

/// Owns one window's attempt. Observable state contains metadata only.
@MainActor @Observable
final class NativePasswordFillCoordinator {
  struct Choice: Identifiable {
    let id: UUID
    let name: String
    let username: String?
  }
  private(set) var entries: [Choice] = []
  private(set) var showingPicker = false
  private(set) var busy = false
  private(set) var message: String?

  @ObservationIgnored private let form: any PasswordFillForm
  @ObservationIgnored private let vault: any PasswordFillVault
  @ObservationIgnored private let binding: () -> PasswordFillBinding?
  @ObservationIgnored private let now: () -> TimeInterval
  @ObservationIgnored private var attempt = UUID()
  @ObservationIgnored private var requestPending = false
  @ObservationIgnored private var context: PasswordFillContext?
  @ObservationIgnored private var handle: NativeBitwardenController.FillHandle?
  @ObservationIgnored private var deadline: TimeInterval = 0
  @ObservationIgnored private var lookup: Task<Void, Never>?
  @ObservationIgnored private var expiry: Task<Void, Never>?

  init(
    form: any PasswordFillForm, vault: any PasswordFillVault,
    binding: @escaping () -> PasswordFillBinding?,
    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.form = form
    self.vault = vault
    self.binding = binding
    self.now = now
  }

  func request() {
    let cancelled = cancel()
    guard attempt == cancelled else { return }
    let id = UUID()
    attempt = id
    guard let owner = binding() else {
      if attempt == id { message = "Password fill unavailable." }
      return
    }
    guard attempt == id else { return }
    guard let access = vault.fillHandle(profileID: owner.profileID) else {
      if attempt == id { message = "Password fill unavailable." }
      return
    }
    guard attempt == id else { return }
    let start = now()
    guard attempt == id else { return }
    let end = start + 30
    guard start.isFinite, end.isFinite, end > start else {
      message = "Password fill unavailable."
      return
    }
    deadline = end
    handle = access
    busy = true
    guard attempt == id else { return }
    expiry = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(30)) } catch { return }
      guard let self, self.attempt == id else { return }
      self.cancel()
    }
    requestPending = true
    guard attempt == id else { return }
    form.request { [weak self] context in
      guard let self, self.attempt == id, self.requestPending else { return }
      self.requestPending = false
      guard let context, context.binding == owner, self.authorized(id, owner: owner, handle: access)
      else {
        guard self.attempt == id else { return }
        let cancelled = self.cancel()
        if self.attempt == cancelled {
          self.message = "No eligible focused password form is available."
        }
        return
      }
      self.context = context
      self.entries = access.pair.snapshot.logins.map {
        Choice(id: $0.id, name: $0.name, username: $0.username)
      }
      self.busy = false
      self.showingPicker = true
    }
  }

  func choose(_ cipherID: UUID) {
    guard let context, let handle, entries.contains(where: { $0.id == cipherID }), !busy else {
      return
    }
    let id = attempt
    guard authorized(id, owner: context.binding, handle: handle) else {
      if attempt == id { cancel() }
      return
    }
    busy = true
    lookup = Task { @MainActor [weak self] in
      guard let self else { return }
      guard !Task.isCancelled, self.authorized(id, owner: context.binding, handle: handle) else {
        if self.attempt == id { self.cancel() }
        return
      }
      do {
        let credential = try await self.vault.fillCredential(
          handle: handle, cipherID: cipherID, context: context)
        guard !Task.isCancelled, self.authorized(id, owner: context.binding, handle: handle) else {
          if self.attempt == id { self.cancel() }
          return
        }
        // No suspension between final authorization and native form handoff.
        self.form.fill(
          context: context, username: credential.username, password: credential.password
        ) { [weak self] success in
          guard let self, self.attempt == id else { return }
          let cancelled = self.cancel()
          if !success && self.attempt == cancelled {
            self.message = "Password fill could not complete."
          }
        }
      } catch {
        guard self.attempt == id else { return }
        let cancelled = self.cancel()
        if self.attempt == cancelled { self.message = "This entry cannot be filled for this form." }
      }
    }
  }

  @discardableResult
  func cancel() -> UUID {
    let cancelled = UUID()
    attempt = cancelled
    lookup?.cancel()
    lookup = nil
    expiry?.cancel()
    expiry = nil
    requestPending = false
    context = nil
    handle = nil
    entries = []
    showingPicker = false
    busy = false
    message = nil
    form.cancel()
    return cancelled
  }

  func vaultDidChange(profileID: UUID) {
    if handle?.binding.profileID == profileID { cancel() }
  }

  private func authorized(
    _ id: UUID, owner: PasswordFillBinding, handle: NativeBitwardenController.FillHandle
  ) -> Bool {
    let time = now()
    let currentOwner = binding()
    let currentHandle = vault.isFillHandleCurrent(handle)
    return time.isFinite && time < deadline && currentOwner == owner && currentHandle
      && attempt == id
  }
}

/// Observes input surfaces that supersede a password attempt.
@MainActor
final class PasswordFillInputMonitor {
  private weak var store: BrowserStore?
  private let onChange: () -> Void
  private var armed = false

  init(store: BrowserStore, onChange: @escaping () -> Void) {
    self.store = store
    self.onChange = onChange
  }

  func arm() {
    guard !armed, let store else { return }
    armed = true
    withObservationTracking {
      _ = store.commandIsOpen
      _ = store.sheet
      _ = store.libraryDrawerSection
      _ = store.pageFind
    } onChange: { [weak self] in
      MainActor.assumeIsolated { self?.inputChanged() }
    }
  }

  private func inputChanged() {
    guard armed else { return }
    armed = false
    onChange()
  }
}

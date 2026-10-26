import BrowserCore
import Foundation
import Observation

@MainActor @Observable
final class NativeBitwardenController {
  @MainActor private final class ProfileState {
    let gate: PasswordAuthenticationGate
    var binding: PasswordAuthenticationBinding
    var generation = 0
    var activeAttempt: PasswordAuthenticationGate.Attempt?
    var activeSession: NativeBitwardenEstablishedSession?
    var pendingCandidateID: UUID?
    var pendingTask: Task<Void, Never>?

    init(binding: PasswordAuthenticationBinding, enabled: Bool) {
      self.binding = binding
      gate = PasswordAuthenticationGate(binding: binding, enabled: enabled)
    }
  }

  private let preferences: BrowserPreferencesStore
  private let backend: any NativeBitwardenBackend
  private let credentialStore: PasswordCredentialStore
  private var profiles: [UUID: ProfileState] = [:]
  private var statusByProfile: [UUID: String] = [:]
  private var providersByProfile: [UUID: [NativeBitwardenMFAProvider]] = [:]
  private var selectedMFAProviderByProfile: [UUID: NativeBitwardenMFAProvider] = [:]
  private var loadingByProfile: [UUID: Bool] = [:]

  private(set) var selectedProfileID: UUID?
  var email = ""
  var masterPassword = ""
  var mfaToken = ""
  var selectedMFAProvider: NativeBitwardenMFAProvider {
    get { selectedProfileID.flatMap { selectedMFAProviderByProfile[$0] } ?? .authenticator }
    set {
      guard let selectedProfileID else { return }
      selectedMFAProviderByProfile[selectedProfileID] = newValue
    }
  }
  var isLoading: Bool {
    selectedProfileID.flatMap { loadingByProfile[$0] } ?? false
  }

  var sdkAvailable: Bool {
    #if canImport(ArcusisBitwardenSDK)
      true
    #else
      false
    #endif
  }

  var hasConnectedSession: Bool {
    guard let selectedProfileID else { return false }
    return profiles[selectedProfileID]?.activeSession != nil
  }

  var hasOwnedCredentials: Bool {
    guard let selectedProfileID else { return false }
    return preferences.nativeVaultPreferences(for: selectedProfileID).accountID != nil
  }

  init(
    preferences: BrowserPreferencesStore,
    backend: any NativeBitwardenBackend = NativeBitwardenSDKBackend(),
    credentialStore: PasswordCredentialStore = PasswordCredentialStore()
  ) {
    self.preferences = preferences
    self.backend = backend
    self.credentialStore = credentialStore
  }

  var status: String {
    guard let selectedProfileID else { return "Choose a Profile to configure its vault." }
    let currentStatus = statusByProfile[selectedProfileID]
    if preferences.nativeVaultPreferences(for: selectedProfileID).isEnabled,
      !sdkAvailable, profiles[selectedProfileID]?.activeSession == nil,
      currentStatus == nil || currentStatus == "Not connected" || currentStatus == "Connecting…"
    {
      return "Native Bitwarden is unavailable in this build."
    }
    if let currentStatus { return currentStatus }
    return preferences.nativeVaultPreferences(for: selectedProfileID).isEnabled
      ? "Not connected" : "Off"
  }

  var supportedMFAProviders: [NativeBitwardenMFAProvider] {
    guard let selectedProfileID else { return [] }
    return providersByProfile[selectedProfileID] ?? []
  }

  var isEnabled: Bool {
    guard let selectedProfileID else { return false }
    return preferences.nativeVaultPreferences(for: selectedProfileID).isEnabled
  }

  var serverConfiguration: BitwardenServerConfiguration {
    guard let selectedProfileID else { return BitwardenServerConfiguration(region: .us) }
    return preferences.nativeVaultPreferences(for: selectedProfileID).server
  }

  func selectProfile(_ profileID: UUID?) {
    guard selectedProfileID != profileID else { return }
    clearForm()
    selectedProfileID = profileID
    guard let profileID else { return }
    _ = state(for: profileID)
  }

  func setEnabled(_ enabled: Bool) {
    guard let profileID = selectedProfileID else { return }
    preferences.setNativeVaultEnabled(enabled, for: profileID)
    let value = state(for: profileID)
    value.generation += 1
    if let attempt = value.activeAttempt { value.gate.invalidate(attempt) }
    value.activeAttempt = nil
    value.pendingTask?.cancel()
    value.pendingTask = nil
    loadingByProfile[profileID] = false
    if let candidateID = value.pendingCandidateID {
      value.pendingCandidateID = nil
      Task { await backend.discard(sessionID: candidateID) }
    }
    value.gate.setEnabled(enabled)
    clearForm()
    if enabled {
      statusByProfile[profileID] = "Not connected"
    } else {
      statusByProfile[profileID] = "Off"
      disconnect(profileID: profileID)
    }
  }

  func setServer(_ server: BitwardenServerConfiguration) {
    guard let profileID = selectedProfileID else { return }
    let value = state(for: profileID)
    let oldBinding = value.binding
    let session = value.activeSession
    value.generation += 1
    if let attempt = value.activeAttempt { value.gate.invalidate(attempt) }
    value.activeAttempt = nil
    value.pendingTask?.cancel()
    value.pendingTask = nil
    let candidateID = value.pendingCandidateID
    value.pendingCandidateID = nil
    loadingByProfile[profileID] = false
    clearForm()
    preferences.setNativeVaultServer(server, for: profileID)
    let updated = preferences.nativeVaultPreferences(for: profileID)
    let newBinding = makeBinding(
      profileID: profileID, preferences: updated, previousAccountID: nil)
    value.binding = newBinding
    value.gate.rebind(to: newBinding)
    value.activeSession = nil
    statusByProfile[profileID] = updated.isEnabled ? "Not connected" : "Off"
    if let session { session.tokenProvider.clear() }
    try? credentialStore.delete(for: oldBinding)
    if let candidateID { Task { await backend.discard(sessionID: candidateID) } }
    if let session {
      Task { await backend.discard(sessionID: session.id) }
    }
  }

  func connect() {
    guard let profileID = selectedProfileID else { return }
    let stored = preferences.nativeVaultPreferences(for: profileID)
    guard stored.isEnabled else {
      statusByProfile[profileID] = "Turn on Bitwarden for this Profile first."
      return
    }
    guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !masterPassword.isEmpty
    else {
      statusByProfile[profileID] = "Enter account email and master password."
      return
    }
    guard let state = refreshBinding(profileID: profileID, preferences: stored) else {
      statusByProfile[profileID] = "Server URL is invalid. Use an HTTPS service URL."
      return
    }
    state.generation += 1
    let generation = state.generation
    if let prior = state.activeAttempt { state.gate.invalidate(prior) }
    state.pendingTask?.cancel()
    if let oldCandidate = state.pendingCandidateID {
      Task { await backend.discard(sessionID: oldCandidate) }
      state.pendingCandidateID = nil
    }
    state.gate.setEnabled(true)
    guard let attempt = state.gate.beginAttempt() else {
      statusByProfile[profileID] = "Connection unavailable."
      return
    }
    state.activeAttempt = attempt
    let emailValue = email.trimmingCharacters(in: .whitespacesAndNewlines)
    let passwordValue = masterPassword
    let factor =
      mfaToken.isEmpty
      ? nil
      : NativeBitwardenSecondFactor(
        provider: selectedMFAProvider, token: mfaToken)
    let server = stored.server
    let deviceID = stored.deviceID
    loadingByProfile[profileID] = true
    statusByProfile[profileID] = "Connecting…"
    state.pendingTask = Task { [weak self] in
      guard let self else { return }
      await self.performConnect(
        profileID: profileID, generation: generation, attempt: attempt,
        server: server, email: emailValue, password: passwordValue,
        deviceID: deviceID, secondFactor: factor)
    }
  }

  func lock() {
    guard let profileID = selectedProfileID, let state = profiles[profileID] else { return }
    let session = state.activeSession
    state.generation += 1
    let generation = state.generation
    if let attempt = state.activeAttempt { state.gate.invalidate(attempt) }
    state.activeAttempt = nil
    state.pendingTask?.cancel()
    state.pendingTask = nil
    let candidateID = state.pendingCandidateID
    state.pendingCandidateID = nil
    loadingByProfile[profileID] = false
    clearForm()
    statusByProfile[profileID] = "Locking…"
    Task {
      if let candidateID { await backend.discard(sessionID: candidateID) }
      guard let session else {
        guard state.generation == generation else { return }
        statusByProfile[profileID] = "Not connected"
        return
      }
      let cleared = await backend.lock(sessionID: session.id)
      guard state.generation == generation, state.activeSession?.id == session.id else { return }
      statusByProfile[profileID] = cleared ? "Locked" : "Could not clear SDK key state."
    }
  }

  func disconnect() {
    guard let profileID = selectedProfileID else { return }
    disconnect(profileID: profileID)
  }

  func closeSettings() {
    clearForm()
    for (profileID, state) in profiles {
      loadingByProfile[profileID] = false
      state.generation += 1
      if let attempt = state.activeAttempt { state.gate.invalidate(attempt) }
      state.activeAttempt = nil
      state.pendingTask?.cancel()
      state.pendingTask = nil
      if let candidateID = state.pendingCandidateID {
        state.pendingCandidateID = nil
        Task { await backend.discard(sessionID: candidateID) }
      }
      _ = profileID
    }
  }

  private func performConnect(
    profileID: UUID, generation: Int, attempt: PasswordAuthenticationGate.Attempt,
    server: BitwardenServerConfiguration, email: String, password: String, deviceID: UUID,
    secondFactor: NativeBitwardenSecondFactor?
  ) async {
    var candidateID: UUID?
    do {
      guard await backend.isAvailable else {
        throw NativeBitwardenBackendError.sdkUnavailable
      }
      switch try await backend.login(
        server: server, email: email, password: password, deviceID: deviceID,
        secondFactor: secondFactor)
      {
      case .challenge(_, let providers):
        guard isCurrent(profileID: profileID, generation: generation, attempt: attempt) else {
          return
        }
        providersByProfile[profileID] = providers
        guard !providers.isEmpty else {
          statusByProfile[profileID] =
            "This account requires a verification method that native Bitwarden does not support."
          loadingByProfile[profileID] = false
          if selectedProfileID == profileID { mfaToken = "" }
          return
        }
        if let preferred = providers.first(where: { $0 == selectedMFAProviderByProfile[profileID] })
        {
          selectedMFAProviderByProfile[profileID] = preferred
        } else if let first = providers.first {
          selectedMFAProviderByProfile[profileID] = first
        }
        statusByProfile[profileID] =
          "Choose a supported verification method and enter its response."
        if selectedProfileID == profileID { mfaToken = "" }
        loadingByProfile[profileID] = false
        return
      case .authenticated(let authenticated):
        candidateID = authenticated.id
        guard isCurrent(profileID: profileID, generation: generation, attempt: attempt) else {
          await backend.discard(sessionID: authenticated.id)
          return
        }
        guard let state = profiles[profileID] else {
          await backend.discard(sessionID: authenticated.id)
          return
        }
        state.pendingCandidateID = authenticated.id
        let preferences = self.preferences.nativeVaultPreferences(for: profileID)
        let realBinding = makeBinding(
          profileID: profileID, preferences: preferences,
          previousAccountID: authenticated.accountID)
        if state.binding != realBinding {
          let oldBinding = state.binding
          let oldSession = state.activeSession
          oldSession?.tokenProvider.clear()
          try? credentialStore.delete(for: oldBinding)
          self.preferences.setNativeVaultAccountID(nil, for: profileID)
          state.activeSession = nil
          if let oldSession { Task { await backend.discard(sessionID: oldSession.id) } }
          state.binding = realBinding
          state.gate.rebind(to: realBinding)
          guard let cryptoAttempt = state.gate.beginAttempt() else {
            await backend.discard(sessionID: authenticated.id)
            return
          }
          state.activeAttempt = cryptoAttempt
          await initializeAndPublish(
            profileID: profileID, generation: generation, attempt: cryptoAttempt,
            candidateID: authenticated.id, password: password, binding: realBinding)
        } else {
          await initializeAndPublish(
            profileID: profileID, generation: generation, attempt: attempt,
            candidateID: authenticated.id, password: password, binding: realBinding)
        }
      }
    } catch {
      if let candidateID { await backend.discard(sessionID: candidateID) }
      if isCurrent(profileID: profileID, generation: generation, attempt: attempt) {
        statusByProfile[profileID] =
          error is NativeBitwardenBackendError
            && (error as? NativeBitwardenBackendError) == .sdkUnavailable
          ? "Native Bitwarden is unavailable in this build."
          : "Connection failed. Check server, email, password, and verification response."
        if selectedProfileID == profileID {
          masterPassword = ""
          mfaToken = ""
        }
        loadingByProfile[profileID] = false
      }
    }
  }

  private func initializeAndPublish(
    profileID: UUID, generation: Int, attempt: PasswordAuthenticationGate.Attempt,
    candidateID: UUID, password: String, binding: PasswordAuthenticationBinding
  ) async {
    do {
      let established = try await backend.initializeCrypto(
        candidateID: candidateID, password: password)
      guard isCurrent(profileID: profileID, generation: generation, attempt: attempt),
        profiles[profileID]?.pendingCandidateID == candidateID
      else {
        established.tokenProvider.clear()
        if profiles[profileID]?.pendingCandidateID == candidateID {
          profiles[profileID]?.pendingCandidateID = nil
        }
        await backend.discard(sessionID: candidateID)
        return
      }
      var writeError: Error?
      var previousSession: NativeBitwardenEstablishedSession?
      let committed =
        profiles[profileID]?.gate.commit(attempt) {
          var previousCredential: PasswordCredential?
          var previousCredentialRead = false
          do {
            previousCredential = try credentialStore.read(for: binding)
            previousCredentialRead = true
            try credentialStore.write(established.credential, for: binding)
            established.tokenProvider.publish(established.credential.accessToken)
            preferences.setNativeVaultAccountID(established.accountID, for: profileID)
            previousSession = profiles[profileID]?.activeSession
            profiles[profileID]?.activeSession = established
            profiles[profileID]?.pendingCandidateID = nil
            loadingByProfile[profileID] = false
            statusByProfile[profileID] = "Connected and unlocked"
          } catch {
            writeError = error
            established.tokenProvider.clear()
            if previousCredentialRead {
              restoreFailedWriteIfOwned(
                established.credential, previousCredential: previousCredential,
                binding: binding, profileID: profileID, generation: generation,
                attempt: attempt, candidateID: candidateID)
            }
          }
        } ?? false
      if !committed || writeError != nil {
        established.tokenProvider.clear()
        let ownsFailureUI =
          generation == profiles[profileID]?.generation
          && profiles[profileID]?.activeAttempt == attempt
          && profiles[profileID]?.pendingCandidateID == candidateID
        if ownsFailureUI {
          profiles[profileID]?.pendingCandidateID = nil
          loadingByProfile[profileID] = false
          statusByProfile[profileID] =
            writeError == nil
            ? "Connection unavailable." : "Could not save credentials securely."
          if selectedProfileID == profileID { clearForm() }
        }
        await backend.discard(sessionID: candidateID)
      } else {
        previousSession?.tokenProvider.clear()
        if selectedProfileID == profileID { clearForm() }
        if let previousSession { await backend.discard(sessionID: previousSession.id) }
      }
    } catch {
      if profiles[profileID]?.pendingCandidateID == candidateID {
        profiles[profileID]?.pendingCandidateID = nil
      }
      await backend.discard(sessionID: candidateID)
      if isCurrent(profileID: profileID, generation: generation, attempt: attempt) {
        statusByProfile[profileID] =
          "Vault crypto initialization failed; credentials were not saved."
        loadingByProfile[profileID] = false
        if selectedProfileID == profileID {
          masterPassword = ""
          mfaToken = ""
        }
      }
    }
  }

  private func restoreFailedWriteIfOwned(
    _ attempted: PasswordCredential, previousCredential: PasswordCredential?,
    binding: PasswordAuthenticationBinding, profileID: UUID, generation: Int,
    attempt: PasswordAuthenticationGate.Attempt, candidateID: UUID
  ) {
    guard generation == profiles[profileID]?.generation,
      profiles[profileID]?.activeAttempt == attempt,
      profiles[profileID]?.pendingCandidateID == candidateID,
      previousCredential != attempted,
      let stored = try? credentialStore.read(for: binding), stored == attempted
    else { return }
    if let previousCredential {
      try? credentialStore.write(previousCredential, for: binding)
    } else {
      try? credentialStore.delete(for: binding)
    }
  }

  private func disconnect(profileID: UUID) {
    guard let state = profiles[profileID] else { return }
    state.generation += 1
    if let attempt = state.activeAttempt { state.gate.invalidate(attempt) }
    state.activeAttempt = nil
    state.pendingTask?.cancel()
    state.pendingTask = nil
    loadingByProfile[profileID] = false
    let session = state.activeSession
    let binding = state.binding
    let candidateID = state.pendingCandidateID
    state.pendingCandidateID = nil
    state.activeSession = nil
    state.gate.setEnabled(false)
    if selectedProfileID == profileID { clearForm() }
    session?.tokenProvider.clear()
    try? credentialStore.delete(for: binding)
    preferences.setNativeVaultAccountID(nil, for: profileID)
    statusByProfile[profileID] =
      preferences.nativeVaultPreferences(for: profileID).isEnabled
      ? "Disconnected" : "Off"
    Task {
      if let candidateID { await backend.discard(sessionID: candidateID) }
      if let session { await backend.discard(sessionID: session.id) }
    }
  }

  private func state(for profileID: UUID) -> ProfileState {
    if let state = profiles[profileID] { return state }
    let value = preferences.nativeVaultPreferences(for: profileID)
    let binding = makeBinding(
      profileID: profileID, preferences: value, previousAccountID: value.accountID)
    let state = ProfileState(binding: binding, enabled: value.isEnabled)
    profiles[profileID] = state
    return state
  }

  private func refreshBinding(
    profileID: UUID, preferences: NativeVaultProfilePreferences
  ) -> ProfileState? {
    guard let endpoints = try? preferences.server.endpoints() else { return nil }
    let oldState = state(for: profileID)
    let binding = PasswordAuthenticationBinding(
      profileID: profileID, vaultID: preferences.vaultID,
      accountID: preferences.accountID ?? oldState.binding.accountID,
      authority: endpoints.credentialAuthority)
    if oldState.binding != binding {
      oldState.gate.rebind(to: binding)
      oldState.binding = binding
    }
    return oldState
  }

  private func makeBinding(
    profileID: UUID, preferences: NativeVaultProfilePreferences, previousAccountID: UUID?
  ) -> PasswordAuthenticationBinding {
    let authority =
      (try? preferences.server.endpoints().credentialAuthority)
      ?? URL(string: "https://invalid.invalid")!
    return PasswordAuthenticationBinding(
      profileID: profileID, vaultID: preferences.vaultID,
      accountID: preferences.accountID ?? previousAccountID ?? UUID(), authority: authority)
  }

  private func isCurrent(
    profileID: UUID, generation: Int, attempt: PasswordAuthenticationGate.Attempt
  ) -> Bool {
    guard let state = profiles[profileID], state.generation == generation,
      state.activeAttempt == attempt,
      preferences.nativeVaultPreferences(for: profileID).isEnabled
    else { return false }
    return true
  }

  private func clearForm() {
    email = ""
    masterPassword = ""
    mfaToken = ""
  }
}

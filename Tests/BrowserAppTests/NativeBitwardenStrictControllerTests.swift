import BrowserCore
import Foundation
import Synchronization
import Testing

@testable import ArcusisBrowser
@testable import BrowserCore

#if ARCUSIS_NATIVE_BITWARDEN_STRICT_SDK && ARCUSIS_NATIVE_BITWARDEN_REFRESH_FIXTURE
  private final class StrictMemoryItems: PasswordCredentialItemStorage, Sendable {
    private let values = Mutex<[String: Data]>([:])
    func read(service: String, account: String) throws -> Data? {
      values.withLock { $0[service + "/" + account] }
    }
    func write(_ data: Data, service: String, account: String) throws {
      values.withLock { $0[service + "/" + account] = data }
    }
    func delete(service: String, account: String) throws {
      _ = values.withLock { $0.removeValue(forKey: service + "/" + account) }
    }
  }

  private actor StrictControllerBackend: NativeBitwardenBackend,
    NativeBitwardenFillCredentialBackend, NativeBitwardenStrictWriteBackend
  {
    struct Plan: Sendable {
      let sessionID: UUID
      let accountID: UUID
      let snapshot: NativeBitwardenVaultSnapshot
      let delayFill: Bool
    }

    private let plans: [Plan]
    private let deferAdoption: Bool
    private var nextPlan = 0
    private var pairs: [UUID: NativeBitwardenFillSnapshotAccess] = [:]
    private var pending: [UUID: CheckedContinuation<NativeBitwardenFillSnapshotAccess, Error>] = [:]
    private var admissions: [UUID: NativeBitwardenWriteAdmission] = [:]
    private var pendingAdoption: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(_ plans: [Plan], deferAdoption: Bool = false) {
      self.plans = plans
      self.deferAdoption = deferAdoption
    }
    var isAvailable: Bool { true }

    func login(
      server: BitwardenServerConfiguration, email: String, password: String, deviceID: UUID,
      secondFactor: NativeBitwardenSecondFactor?
    ) async throws -> NativeBitwardenLoginResult {
      guard nextPlan < plans.count else { throw NativeBitwardenBackendError.candidateUnavailable }
      let plan = plans[nextPlan]
      nextPlan += 1
      return .authenticated(.init(id: plan.sessionID, accountID: plan.accountID))
    }

    func initializeCrypto(candidateID: UUID, password: String) async throws
      -> NativeBitwardenEstablishedSession
    {
      guard let plan = plans.first(where: { $0.sessionID == candidateID }) else {
        throw NativeBitwardenBackendError.candidateUnavailable
      }
      return .init(
        id: candidateID, accountID: plan.accountID,
        credential: PasswordCredential(
          accessToken: "synthetic-access", refreshToken: "synthetic-refresh"),
        tokenProvider: NativeBitwardenTokenProvider())
    }

    func syncVault(sessionID: UUID) async throws -> NativeBitwardenVaultSnapshot {
      guard let plan = plans.first(where: { $0.sessionID == sessionID }) else {
        throw NativeBitwardenBackendError.candidateUnavailable
      }
      var state = NativeBitwardenFillAccessState<UUID>(sessionID: sessionID)
      let ticket = try state.beginSync()
      try state.publish(ticket: ticket, snapshot: plan.snapshot, items: [:])
      state.finishSync(ticket)
      pairs[sessionID] = try state.snapshot()
      return plan.snapshot
    }

    func fillSnapshot(sessionID: UUID) async throws -> NativeBitwardenFillSnapshotAccess {
      guard let pair = pairs[sessionID], let plan = plans.first(where: { $0.sessionID == sessionID })
      else { throw NativeBitwardenFillError.staleAccess }
      if plan.delayFill {
        return try await withCheckedThrowingContinuation { pending[sessionID] = $0 }
      }
      return pair
    }

    func releaseFill(_ sessionID: UUID) {
      guard let continuation = pending.removeValue(forKey: sessionID), let pair = pairs[sessionID]
      else { return }
      continuation.resume(returning: pair)
    }
    func fillPending(_ sessionID: UUID) -> Bool { pending[sessionID] != nil }
    func fillCredential(
      access: NativeBitwardenFillAccess, cipherID: UUID, context: PasswordFillContext
    ) async throws -> NativeBitwardenFillCredential { throw NativeBitwardenFillError.staleAccess }
    func lock(sessionID: UUID) async -> Bool { true }
    func discard(sessionID: UUID) async {}
    func adoptStrictWriteAuthority(_ admission: NativeBitwardenWriteAdmission) async throws {
      let id = admission.lease.binding.access.sessionID
      admissions[id] = admission
      if deferAdoption {
        await withCheckedContinuation { pendingAdoption[id] = $0 }
      }
    }
    func releaseAdoption(_ sessionID: UUID) {
      pendingAdoption.removeValue(forKey: sessionID)?.resume()
    }
    func isCurrent(_ sessionID: UUID) -> Bool {
      guard let admission = admissions[sessionID] else { return false }
      return admission.authority.isCurrent(admission.lease)
    }
    func adopted(_ sessionID: UUID) -> Bool { admissions[sessionID] != nil }
    func prepareStrictUpdate(
      access: NativeBitwardenFillAccess, context: PasswordFillContext, cipherID: UUID
    ) async throws -> NativeBitwardenStrictUpdateHandle {
      throw NativeBitwardenWriteError.staleAccess
    }
    func cancelStrictUpdate(sessionID: UUID, handle: NativeBitwardenStrictUpdateHandle) async {}
    func strictUpdate(
      access: NativeBitwardenFillAccess, context: PasswordFillContext,
      handle: NativeBitwardenStrictUpdateHandle, input: NativeBitwardenStrictUpdateInput
    ) async throws { throw NativeBitwardenWriteError.staleAccess }
  }

  @Suite @MainActor
  struct NativeBitwardenStrictControllerTests {
    private func controller(_ backend: StrictControllerBackend) throws
      -> (NativeBitwardenController, URL)
    {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("strict-controller-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      return (
        NativeBitwardenController(
          preferences: BrowserPreferencesStore(fileURL: directory.appendingPathComponent("preferences.json")),
          backend: backend,
          credentialStore: PasswordCredentialStore(
            service: "strict-controller-memory", storage: StrictMemoryItems())),
        directory
      )
    }

    private func start(_ controller: NativeBitwardenController, profile: UUID) {
      controller.selectProfile(profile)
      controller.setEnabled(true)
      controller.email = "synthetic@example.test"
      controller.masterPassword = "synthetic-password"
      controller.connect()
    }

    private func awaitCondition(_ predicate: () async -> Bool) async -> Bool {
      for _ in 0..<200 {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(5))
      }
      return false
    }

    @Test func controllerRevokesSynchronouslyAndSelectionDoesNotRevokeOtherProfile() async throws {
      let first = StrictControllerBackend.Plan(
        sessionID: UUID(), accountID: UUID(), snapshot: .empty, delayFill: false)
      let second = StrictControllerBackend.Plan(
        sessionID: UUID(), accountID: UUID(), snapshot: .empty, delayFill: false)
      let backend = StrictControllerBackend([first, second])
      let (subject, directory) = try controller(backend)
      defer { try? FileManager.default.removeItem(at: directory) }
      let firstProfile = UUID(), secondProfile = UUID()
      start(subject, profile: firstProfile)
      try #require(await awaitCondition { await backend.adopted(first.sessionID) })
      start(subject, profile: secondProfile)
      try #require(await awaitCondition { await backend.adopted(second.sessionID) })
      #expect(await backend.isCurrent(first.sessionID))
      #expect(await backend.isCurrent(second.sessionID))
      subject.lock()
      #expect(!(await backend.isCurrent(second.sessionID)))
      #expect(await backend.isCurrent(first.sessionID))
      subject.selectProfile(firstProfile)
      #expect(await backend.isCurrent(first.sessionID))
      subject.setEnabled(false)
      #expect(!(await backend.isCurrent(first.sessionID)))
    }

    @Test func delayedFillCannotAdoptAfterLockDisableDisconnectOrServerChange() async throws {
      for operation in 0..<4 {
        let plan = StrictControllerBackend.Plan(
          sessionID: UUID(), accountID: UUID(), snapshot: .empty, delayFill: true)
        let backend = StrictControllerBackend([plan])
        let (subject, directory) = try controller(backend)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = UUID()
        start(subject, profile: profile)
        let task = try #require(subject.strictFixturePendingTask(profileID: profile))
        try #require(await awaitCondition { await backend.fillPending(plan.sessionID) })
        switch operation {
        case 0: subject.lock()
        case 1: subject.setEnabled(false)
        case 2: subject.disconnect()
        default: subject.setServer(BitwardenServerConfiguration(region: .eu))
        }
        await backend.releaseFill(plan.sessionID)
        await task.value
        #expect(!(await backend.adopted(plan.sessionID)))
        #expect(subject.fillHandle(profileID: profile).map { _ in true } == nil)
      }
    }

    @Test func disconnectAndServerChangeRevokeAcceptedAuthority() async throws {
      for operation in 0..<2 {
        let plan = StrictControllerBackend.Plan(
          sessionID: UUID(), accountID: UUID(), snapshot: .empty, delayFill: false)
        let backend = StrictControllerBackend([plan])
        let (subject, directory) = try controller(backend)
        defer { try? FileManager.default.removeItem(at: directory) }
        start(subject, profile: UUID())
        try #require(await awaitCondition { await backend.adopted(plan.sessionID) })
        #expect(await backend.isCurrent(plan.sessionID))
        if operation == 0 {
          subject.disconnect()
        } else {
          subject.setServer(BitwardenServerConfiguration(region: .eu))
        }
        #expect(!(await backend.isCurrent(plan.sessionID)))
      }
    }

    @Test func delayedBackendAdoptionCannotReviveAfterLock() async throws {
      let plan = StrictControllerBackend.Plan(
        sessionID: UUID(), accountID: UUID(), snapshot: .empty, delayFill: false)
      let backend = StrictControllerBackend([plan], deferAdoption: true)
      let (subject, directory) = try controller(backend)
      defer { try? FileManager.default.removeItem(at: directory) }
      let profile = UUID()
      start(subject, profile: profile)
      let task = try #require(subject.strictFixturePendingTask(profileID: profile))
      try #require(await awaitCondition { await backend.adopted(plan.sessionID) })
      #expect(await backend.isCurrent(plan.sessionID))
      subject.lock()
      #expect(!(await backend.isCurrent(plan.sessionID)))
      await backend.releaseAdoption(plan.sessionID)
      await task.value
      #expect(!(await backend.isCurrent(plan.sessionID)))
      #expect(subject.fillHandle(profileID: profile).map { _ in true } == nil)
    }

    @Test func reconnectRevokesOldAccountBeforeNewSnapshotAdoption() async throws {
      let first = StrictControllerBackend.Plan(
        sessionID: UUID(), accountID: UUID(), snapshot: .empty, delayFill: false)
      let replacement = StrictControllerBackend.Plan(
        sessionID: UUID(), accountID: UUID(), snapshot: .empty, delayFill: false)
      let backend = StrictControllerBackend([first, replacement])
      let (subject, directory) = try controller(backend)
      defer { try? FileManager.default.removeItem(at: directory) }
      start(subject, profile: UUID())
      try #require(await awaitCondition { await backend.adopted(first.sessionID) })
      subject.email = "other@example.test"
      subject.masterPassword = "synthetic-password"
      subject.connect()
      #expect(!(await backend.isCurrent(first.sessionID)))
      try #require(await awaitCondition { await backend.adopted(replacement.sessionID) })
      #expect(await backend.isCurrent(replacement.sessionID))
    }
  }
#endif

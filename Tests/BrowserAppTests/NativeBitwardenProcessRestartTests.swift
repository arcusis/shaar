#if ARCUSIS_NATIVE_BITWARDEN_REFRESH_FIXTURE && canImport(ArcusisBitwardenSDK)
  import ArcusisBitwardenSDK
  import BrowserCore
  import CryptoKit
  import Darwin
  import Foundation
  import Synchronization
  import XCTest

  @testable import ArcusisBrowser
  @testable import BrowserCore

  private struct RestartVector: Decodable, Sendable {
    let phase: String
    let directory: String
    let endpoint: String
    let profileID: String
    let userID: String
    let email: String
    let currentPassword: String
  }

  private final class RestartFileItems: PasswordCredentialItemStorage, @unchecked Sendable {
    private let directory: URL
    private let mutex = NSLock()

    init(directory: URL) throws {
      self.directory = directory
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func path(service: String, account: String) -> URL {
      let digest = SHA256.hash(data: Data((service + "\u{0}" + account).utf8))
      return directory.appending(path: digest.map { String(format: "%02x", $0) }.joined() + ".json")
    }

    func read(service: String, account: String) throws -> Data? {
      mutex.lock()
      defer { mutex.unlock() }
      let file = path(service: service, account: account)
      guard FileManager.default.fileExists(atPath: file.path) else { return nil }
      return try Data(contentsOf: file)
    }

    func write(_ data: Data, service: String, account: String) throws {
      mutex.lock()
      defer { mutex.unlock() }
      let file = path(service: service, account: account)
      try data.write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      let handle = try FileHandle(forWritingTo: file)
      defer { try? handle.close() }
      try handle.synchronize()
      let fd = open(directory.path, O_RDONLY | O_DIRECTORY)
      guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
      defer { close(fd) }
      guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    func delete(service: String, account: String) throws {
      mutex.lock()
      defer { mutex.unlock() }
      let file = path(service: service, account: account)
      if FileManager.default.fileExists(atPath: file.path) {
        try FileManager.default.removeItem(at: file)
      }
    }

    func onlyRecord() throws -> Data {
      mutex.lock()
      defer { mutex.unlock() }
      let files = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
      ).filter { $0.pathExtension == "json" }
      guard files.count == 1 else { throw CocoaError(.fileReadCorruptFile) }
      return try Data(contentsOf: files[0])
    }
  }

  private final class RestartProviderCapture: Sendable {
    private let value = Mutex<NativeBitwardenTokenProvider?>(nil)
    func set(_ provider: NativeBitwardenTokenProvider) { value.withLock { $0 = provider } }
    func latest() -> NativeBitwardenTokenProvider? { value.withLock { $0 } }
  }

  final class NativeBitwardenProcessRestartTests: XCTestCase {
    @MainActor func testOwnedProcessRestartPhase() async throws {
      let encoded = try XCTUnwrap(
        ProcessInfo.processInfo.environment["ARCUSIS_PROCESS_RESTART_FIXTURE"])
      let payload = try JSONDecoder().decode(
        RestartVector.self, from: try XCTUnwrap(Data(base64Encoded: encoded)))
      let endpoint = try XCTUnwrap(URL(string: payload.endpoint))
      guard endpoint.scheme == "http", endpoint.host == "127.0.0.1", endpoint.port != nil,
        endpoint.path.isEmpty, endpoint.user == nil, endpoint.password == nil,
        endpoint.query == nil, endpoint.fragment == nil
      else {
        XCTFail("Invalid owned endpoint")
        return
      }
      let root = URL(fileURLWithPath: payload.directory, isDirectory: true)
        .resolvingSymlinksInPath()
      let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      guard root.path.hasPrefix(temporary.path + "/"),
        try String(contentsOf: root.appending(path: "owned-marker"), encoding: .utf8)
          == "arcusis-process-restart-fixture"
      else {
        XCTFail("Invalid owned fixture directory")
        return
      }
      let profile = try XCTUnwrap(UUID(uuidString: payload.profileID))
      let account = try XCTUnwrap(UUID(uuidString: payload.userID))
      let preferencesFile = root.appending(path: "preferences.json")
      let items = try RestartFileItems(directory: root.appending(path: "items"))
      let credentials = PasswordCredentialStore(
        service: "owned-process-restart", storage: items, sessionLockDirectory: root,
        usesSessionLocks: true)
      let prefs = BrowserPreferencesStore(fileURL: preferencesFile)
      let capture = RestartProviderCapture()
      let backend = NativeBitwardenSDKBackend { provider, settings in
        capture.set(provider)
        let local = ClientSettings(
          identityUrl: payload.endpoint + "/identity", apiUrl: payload.endpoint + "/api",
          userAgent: settings.userAgent, deviceType: .sdk,
          deviceIdentifier: settings.deviceIdentifier,
          bitwardenClientVersion: settings.bitwardenClientVersion,
          bitwardenPackageType: settings.bitwardenPackageType)
        return Client(
          tokenProvider: provider, settings: local, managedSettings: ManagedSettingsBindingClient())
      }
      let available = await backend.isAvailable
      XCTAssertTrue(available)
      if payload.phase == "initial" {
        prefs.setNativeVaultServer(
          BitwardenServerConfiguration(region: .custom, customBaseURL: "https://fixture.example"),
          for: profile)
        prefs.setNativeVaultEnabled(true, for: profile)
      }
      let controller = NativeBitwardenController(
        preferences: prefs, backend: backend, credentialStore: credentials)
      controller.selectProfile(profile)
      XCTAssertFalse(controller.hasConnectedSession)
      XCTAssertTrue(controller.masterPassword.isEmpty)
      XCTAssertNil(controller.fillHandle(profileID: profile))

      func currentRecord() throws -> (PasswordSessionRecoveryRecord, String) {
        let settings = prefs.nativeVaultPreferences(for: profile)
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.accountID, account)
        let endpoints = try settings.server.endpoints()
        let binding = PasswordAuthenticationBinding(
          profileID: profile, vaultID: settings.vaultID, accountID: account,
          authority: endpoints.credentialAuthority)
        let raw = try items.onlyRecord()
        XCTAssertFalse(raw.range(of: Data(payload.currentPassword.utf8)) != nil)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let allowed: Set<String> = [
          "version", "profileID", "vaultID", "accountID", "authority", "identityURL", "apiURL",
          "serviceID", "deviceID", "clientID", "email", "sdkRevision", "kdf", "wrappedAccountState",
          "masterPasswordUnlockData", "accessToken", "refreshToken", "expiresAt", "revision",
          "state",
        ]
        XCTAssertTrue(Set(object.keys).isSubset(of: allowed))
        let record = try PasswordSessionRecoveryRecord.decode(
          raw, binding: binding, identityURL: endpoints.identityURL, apiURL: endpoints.apiURL,
          serviceID: endpoints.stableServiceID, deviceID: settings.deviceID,
          clientID: NativeBitwardenLoginRequestMetadata.clientID,
          sdkRevision: NativeBitwardenController.recoverySDKRevision)
        let bindingValue = [
          profile.uuidString, settings.vaultID.uuidString, account.uuidString,
          endpoints.credentialAuthority.absoluteString, endpoints.identityURL.absoluteString,
          endpoints.apiURL.absoluteString, endpoints.stableServiceID, settings.deviceID.uuidString,
          record.clientID,
        ].joined(separator: "|")
        let fingerprint = SHA256.hash(data: Data(bindingValue.utf8))
          .map { String(format: "%02x", $0) }.joined()
        return (record, fingerprint)
      }

      if payload.phase == "crash" {
        let (before, _) = try currentRecord()
        XCTAssertEqual(before.state, .ready)
        XCTAssertEqual(before.revision, 2)
        XCTAssertLessThan(try XCTUnwrap(before.credential.expiresAt), Date().addingTimeInterval(60))
        controller.email = payload.email
        controller.masterPassword = payload.currentPassword
        controller.connect()
        try await Task.sleep(for: .seconds(40))
        XCTFail("Consumed refresh did not cause controlled termination")
        return
      }
      if payload.phase == "afterCrash" {
        let (intent, _) = try currentRecord()
        XCTAssertEqual(intent.state, .refreshInFlight)
        XCTAssertEqual(intent.revision, 2)
        let settings = prefs.nativeVaultPreferences(for: profile)
        let binding = PasswordAuthenticationBinding(
          profileID: profile, vaultID: settings.vaultID, accountID: account,
          authority: try settings.server.endpoints().credentialAuthority)
        var lease: PasswordCredentialSessionLock? = try credentials.acquireSessionLock(for: binding)
        XCTAssertTrue(try XCTUnwrap(lease).hasPendingRotation())
        lease = nil
        do {
          _ = try await backend.restoreLocked(record: intent, server: settings.server)
          XCTFail("Interrupted rotation restored locked candidate")
        } catch {
          XCTAssertEqual(error as? NativeBitwardenBackendError, .sessionLocked)
        }
        XCTAssertNil(capture.latest())
        try Data("ready".utf8).write(to: root.appending(path: "crash-ready"), options: .atomic)
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: root.appending(path: "crash-continue").path),
          Date() < deadline
        { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(
          FileManager.default.fileExists(atPath: root.appending(path: "crash-continue").path))
      } else if payload.phase == "restore" {
        let (before, _) = try currentRecord()
        XCTAssertEqual(before.state, .ready)
        XCTAssertEqual(before.revision, 1)
        XCTAssertLessThan(try XCTUnwrap(before.credential.expiresAt), Date())
        let candidate = try await backend.restoreLocked(
          record: before, server: prefs.nativeVaultPreferences(for: profile).server)
        let lockedProvider = try XCTUnwrap(capture.latest())
        let tokenBeforePassword = await lockedProvider.getAccessToken()
        XCTAssertNil(tokenBeforePassword)
        do {
          _ = try await backend.syncVault(sessionID: candidate)
          XCTFail("Locked candidate accepted sync")
        } catch {
          XCTAssertEqual(error as? NativeBitwardenBackendError, .staleSession)
        }
        do {
          _ = try await backend.unlockRestored(
            sessionID: candidate, record: before, password: "wrong synthetic password")
          XCTFail("Wrong password unlocked candidate")
        } catch {}
        let tokenAfterWrongPassword = await lockedProvider.getAccessToken()
        XCTAssertNil(tokenAfterWrongPassword)
        do {
          _ = try await backend.syncVault(sessionID: candidate)
          XCTFail("Wrong password allowed sync")
        } catch {
          XCTAssertEqual(error as? NativeBitwardenBackendError, .staleSession)
        }
        await backend.discard(sessionID: candidate)
        try Data("ready".utf8).write(to: root.appending(path: "locked-ready"), options: .atomic)
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: root.appending(path: "continue").path),
          Date() < deadline
        { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "continue").path))
      } else {
        XCTAssertEqual(payload.phase, "initial")
      }
      controller.email = payload.email
      controller.masterPassword = payload.currentPassword
      controller.connect()
      for _ in 0..<800 {
        if controller.syncStatus.hasPrefix("Synced")
          || controller.syncStatus.hasPrefix("Sync failed")
        {
          break
        }
        if !controller.isLoading && controller.status.contains("failed") { break }
        try await Task.sleep(for: .milliseconds(25))
      }
      XCTAssertTrue(controller.syncStatus.hasPrefix("Synced"))
      XCTAssertTrue(controller.hasConnectedSession)
      XCTAssertTrue(controller.masterPassword.isEmpty)
      let (record, fingerprint) = try currentRecord()
      XCTAssertEqual(record.state, .ready)
      let expectedRevision: UInt64 =
        payload.phase == "initial" ? 1 : (payload.phase == "restore" ? 2 : 0)
      XCTAssertEqual(record.revision, expectedRevision)
      let expectedRefresh =
        payload.phase == "initial"
        ? "synthetic-rotated-one"
        : (payload.phase == "restore" ? "synthetic-rotated-two" : "synthetic-fresh-login")
      XCTAssertTrue(record.credential.refreshToken == expectedRefresh)
      let provider = try XCTUnwrap(capture.latest())
      let publishedToken = await provider.getAccessToken()
      XCTAssertTrue(publishedToken == record.credential.accessToken)
      controller.lock()
      for _ in 0..<200 {
        if controller.status == "Locked" { break }
        try await Task.sleep(for: .milliseconds(25))
      }
      XCTAssertEqual(controller.status, "Locked")
      let tokenAfterLock = await provider.getAccessToken()
      XCTAssertNil(tokenAfterLock)
      let refreshDigest = SHA256.hash(data: Data(expectedRefresh.utf8))
        .map { String(format: "%02x", $0) }.joined()
      let receipt: [String: Any] = [
        "phase": payload.phase, "pid": getpid(), "binding": fingerprint,
        "revision": record.revision, "refreshDigest": refreshDigest,
        "locked": true, "providerCleared": true, "noPlaintextPassword": true,
      ]
      let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
      try data.write(to: root.appending(path: payload.phase + ".json"), options: .atomic)
    }
  }
#endif

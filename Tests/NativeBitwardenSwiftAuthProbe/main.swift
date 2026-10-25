import BitwardenFFI
import Foundation

private let email = "test@example.com"
private let password = "test_password"
private let clientID = "arcusis-browser-synthetic-probe"
private let deviceID = "00000000-0000-4000-8000-000000000026"

private func waitForHeldLogin(_ endpoint: URL) async throws {
  let waitingURL = endpoint.appending(path: "probe/waiting")
  for _ in 0..<150 {
    let (data, _) = try await URLSession.shared.data(from: waitingURL)
    if data == Data("waiting".utf8) { return }
    try await Task.sleep(for: .milliseconds(20))
  }
  throw SafeFailure()
}

private func releaseHeldLogin(_ endpoint: URL) async throws {
  var request = URLRequest(url: endpoint.appending(path: "probe/release"))
  request.httpMethod = "POST"
  _ = try await URLSession.shared.data(for: request)
}

private struct SafeFailure: Error {}

private final class EmptyTokenProvider: ClientManagedTokens {
  func getAccessToken() async -> String? { nil }
}

@MainActor
func runSwiftAuthProbe() async {
  guard CommandLine.arguments.count == 3,
    let endpoint = URL(string: CommandLine.arguments[1]),
    endpoint.scheme == "http", endpoint.host == "127.0.0.1",
    endpoint.port != nil, endpoint.path.isEmpty || endpoint.path == "/",
    ["normal", "malformed", "cancel", "ownership"].contains(CommandLine.arguments[2])
  else {
    print("swift_probe=invalid_input")
    exit(2)
  }
  let mode = CommandLine.arguments[2]
  do {
    let settings = ClientSettings(
      identityUrl: endpoint.absoluteString + "identity",
      apiUrl: endpoint.absoluteString + "api",
      userAgent: "Arcusis Swift auth proof",
      deviceType: .sdk,
      deviceIdentifier: deviceID,
      bitwardenClientVersion: "0.0.0-synthetic",
      bitwardenPackageType: "desktop")
    let client = Client(
      tokenProvider: EmptyTokenProvider(), settings: settings,
      managedSettings: ManagedSettingsBindingClient())
    let login = client.auth().login()
    let prelogin = try await login.getPasswordPrelogin(email: email)
    let request = PasswordLoginRequest(
      loginRequest: LoginRequest(
        clientId: clientID,
        device: LoginDeviceRequest(
          deviceType: .sdk, deviceIdentifier: deviceID,
          deviceName: "Synthetic Swift Probe", devicePushToken: nil)),
      email: email, password: password, preloginResponse: prelogin, twoFactor: nil)
    let retry = PasswordLoginRequest(
      loginRequest: request.loginRequest, email: email, password: password,
      preloginResponse: prelogin,
      twoFactor: TwoFactorRequest(token: "123456", provider: .authenticator, remember: false))

    if mode == "malformed" {
      do {
        _ = try await login.loginViaPassword(request: request)
        throw SafeFailure()
      } catch is SafeFailure {
        throw SafeFailure()
      } catch let error as BitwardenError {
        guard case .PasswordLogin(.Unknown(let message)) = error,
          message.contains("Two-factor challenge contained no supported providers.")
        else { throw SafeFailure() }
        print("swift_malformed_challenge=rejected")
        return
      }
    }
    if mode == "cancel" {
      let pending = Task { try await login.loginViaPassword(request: request) }
      try await Task.sleep(for: .milliseconds(250))
      pending.cancel()
      FileHandle.standardOutput.write(Data("swift_cancellation=requested\n".utf8))
      do {
        _ = try await pending.value
        throw SafeFailure()
      } catch is SafeFailure {
        throw SafeFailure()
      } catch {
        print("swift_cancellation=observed")
        return
      }
    }
    if mode == "ownership" {
      let hostBinding = PasswordAuthenticationBinding(
        profileID: UUID(uuidString: "00000000-0000-4000-8000-000000000101")!,
        vaultID: UUID(uuidString: "00000000-0000-4000-8000-000000000201")!,
        accountID: UUID(uuidString: "00000000-0000-4000-8000-000000000301")!,
        authority: URL(string: endpoint.absoluteString)!)
      let otherProfileBinding = PasswordAuthenticationBinding(
        profileID: UUID(uuidString: "00000000-0000-4000-8000-000000000102")!,
        vaultID: hostBinding.vaultID, accountID: hostBinding.accountID,
        authority: hostBinding.authority)
      let hostGate = PasswordAuthenticationGate(binding: hostBinding)
      let otherProfileGate = PasswordAuthenticationGate(binding: otherProfileBinding)
      guard let lateAttempt = hostGate.beginAttempt(),
        let profileAttempt = otherProfileGate.beginAttempt()
      else { throw SafeFailure() }
      let pending = Task { try await login.loginViaPassword(request: retry) }
      try await waitForHeldLogin(endpoint)
      hostGate.invalidate(lateAttempt)
      guard let currentAttempt = hostGate.beginAttempt() else { throw SafeFailure() }
      try await releaseHeldLogin(endpoint)
      guard case .authenticated = try await pending.value else { throw SafeFailure() }
      var latePublicationRan = false
      let lateDiscarded = !hostGate.commit(lateAttempt) { latePublicationRan = true }
      let freshLogin = try await login.loginViaPassword(request: retry)
      var freshPublicationRan = false
      let freshAccepted: Bool
      if case .authenticated = freshLogin {
        freshAccepted = hostGate.commit(currentAttempt) { freshPublicationRan = true }
      } else {
        freshAccepted = false
      }
      var profilePublicationRan = false
      let profileAccepted = otherProfileGate.commit(profileAttempt) {
        profilePublicationRan = true
      }
      guard lateDiscarded, !latePublicationRan, freshAccepted, freshPublicationRan,
        profileAccepted, profilePublicationRan
      else { throw SafeFailure() }
      print("late_sdk_success_observed=passed")
      print("late_publication_rejected=passed")
      print("fresh_sdk_success_published=passed")
      print("independent_profile_attempt_valid=passed")
      print("integration_ready=false")
      return
    }
    guard
      case .twoFactorRequired(let challenge) = try await login.loginViaPassword(request: request),
      challenge.providers.contains(.authenticator)
    else { throw SafeFailure() }
    print("mfa_challenge=passed")

    guard case .authenticated = try await login.loginViaPassword(request: retry) else {
      throw SafeFailure()
    }
    print("mfa_retry_success=passed")

    let invalid = PasswordLoginRequest(
      loginRequest: request.loginRequest, email: email, password: password,
      preloginResponse: prelogin,
      twoFactor: TwoFactorRequest(token: "000000", provider: .authenticator, remember: false))
    do {
      _ = try await login.loginViaPassword(request: invalid)
      throw SafeFailure()
    } catch is SafeFailure {
      throw SafeFailure()
    } catch let failure as BitwardenError {
      guard case .PasswordLogin(let error) = failure else { throw SafeFailure() }
      switch error {
      case .Unknown(let message)
      where message.contains("Two-factor challenge response was invalid."):
        break
      default:
        throw SafeFailure()
      }
    }
    print("invalid_mfa=passed")
    print("swift_auth=passed")
  } catch {
    // SDK errors can contain response bodies. Never print localizedDescription.
    print("swift_auth=failed")
    exit(1)
  }
}

await runSwiftAuthProbe()

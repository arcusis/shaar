import BitwardenFFI
import Foundation

private let email = "test@example.com"
private let password = "test_password"
private let clientID = "arcusis-browser-synthetic-probe"
private let deviceID = "00000000-0000-4000-8000-000000000026"

private struct SafeFailure: Error {}

private final class EmptyTokenProvider: ClientManagedTokens {
  func getAccessToken() async -> String? { nil }
}

func runSwiftAuthProbe() async {
  guard CommandLine.arguments.count == 3,
    let endpoint = URL(string: CommandLine.arguments[1]),
    endpoint.scheme == "http", endpoint.host == "127.0.0.1",
    endpoint.port != nil, endpoint.path.isEmpty || endpoint.path == "/",
    ["normal", "malformed", "cancel"].contains(CommandLine.arguments[2])
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
    guard
      case .twoFactorRequired(let challenge) = try await login.loginViaPassword(request: request),
      challenge.providers.contains(.authenticator)
    else { throw SafeFailure() }
    print("mfa_challenge=passed")

    let retry = PasswordLoginRequest(
      loginRequest: request.loginRequest, email: email, password: password,
      preloginResponse: prelogin,
      twoFactor: TwoFactorRequest(token: "123456", provider: .authenticator, remember: false))
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

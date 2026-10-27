import ArcusisBitwardenSDK
import Foundation

private final class SyntheticTokens: ClientManagedTokens {
  func getAccessToken() async -> String? { "fixture-access" }
}

private enum Failure: Error { case invalid }

@main
struct DeadlineProbe {
  static func main() async throws {
    guard CommandLine.arguments.count == 3, let port = UInt16(CommandLine.arguments[1]), port > 0
    else { throw Failure.invalid }
    let root = "http://127.0.0.1:\(port)"
    let settings = ClientSettings(
      identityUrl: root + "/identity", apiUrl: root + "/api", userAgent: "deadline-fixture",
      deviceType: .sdk, deviceIdentifier: "00000000-0000-4000-8000-000000000026",
      bitwardenClientVersion: "0.0.0-synthetic", bitwardenPackageType: "desktop")
    let client = Client(
      tokenProvider: SyntheticTokens(), settings: settings,
      managedSettings: ManagedSettingsBindingClient())
    if CommandLine.arguments[2] == "stall" {
      do {
        _ = try await client.auth().refreshPasswordManagerToken(
          refreshToken: "fixture-refresh", clientId: "fixture-client",
          email: "fixture@example.invalid", kdf: .pbkdf2(iterations: 600_000))
        throw Failure.invalid
      } catch RefreshError.RequestFailed {
        print("SDK_DEADLINE_TIMEOUT_OK")
      }
    } else if CommandLine.arguments[2] == "flow" {
      let first = try await client.auth().refreshPasswordManagerToken(
        refreshToken: "fixture-refresh", clientId: "fixture-client",
        email: "fixture@example.invalid", kdf: .pbkdf2(iterations: 600_000))
      guard first.expiresIn == 3600 && first.refreshToken == nil else { throw Failure.invalid }
      let second = try await client.auth().refreshPasswordManagerToken(
        refreshToken: "fixture-refresh", clientId: "fixture-client",
        email: "fixture@example.invalid", kdf: .pbkdf2(iterations: 600_000))
      guard second.expiresIn == 3600 && second.refreshToken == "fixture-rotated" else {
        throw Failure.invalid
      }
      let unauthorized = await client.sync().syncWithOutcome(force: true)
      guard case .unauthorized = unauthorized else { throw Failure.invalid }
      let failed = await client.sync().syncWithOutcome(force: true)
      guard case .failed = failed else { throw Failure.invalid }
      print("SDK_DEADLINE_FLOW_OK")
    } else {
      throw Failure.invalid
    }
  }
}

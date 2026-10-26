import ArcusisBitwardenSDK
import Foundation

private final class SyntheticTokens: ClientManagedTokens {
    func getAccessToken() async -> String? { nil }
}

private enum ProbeFailure: Error { case unexpected }

@main
struct RefreshPackageProbe {
    static func main() async throws {
        let settings = ClientSettings(
            identityUrl: "http://127.0.0.1:1/identity",
            apiUrl: "http://127.0.0.1:1/api",
            userAgent: "native-refresh-package-probe",
            deviceType: .sdk,
            deviceIdentifier: "00000000-0000-4000-8000-000000000026",
            bitwardenClientVersion: "0.0.0-synthetic",
            bitwardenPackageType: "desktop")
        let client = Client(tokenProvider: SyntheticTokens(), settings: settings,
                            managedSettings: ManagedSettingsBindingClient())
        do {
            _ = try await client.auth().refreshPasswordManagerToken(
                refreshToken: "", clientId: "synthetic", email: "synthetic@example.invalid",
                kdf: .pbkdf2(iterations: 600_000))
            throw ProbeFailure.unexpected
        } catch RefreshError.InvalidInput {
            // Input is rejected before any request.
        } catch {
            throw ProbeFailure.unexpected
        }
        let outcome = await client.sync().syncWithOutcome(force: true)
        guard case .failed = outcome else { throw ProbeFailure.unexpected }
        let cases: [SyncOutcome] = [.synced, .unchanged, .unauthorized, .failed]
        guard cases.count == 4 else { throw ProbeFailure.unexpected }
        print("SDK_REFRESH_CANDIDATE_OK")
    }
}

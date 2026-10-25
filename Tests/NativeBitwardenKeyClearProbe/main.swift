import BitwardenFFI
import Foundation

@main
struct NativeBitwardenKeyClearProbe {
  static func main() async throws {
    let fixture = try NativeCryptoFixture.load()
    let client = try await makeInitializedClient(fixture: fixture)
    let independentClient = try await makeInitializedClient(fixture: fixture)
    let crypto = client.crypto()
    let ciphers = client.vault().ciphers()
    let independentCiphers = independentClient.vault().ciphers()
    let view = makeSyntheticCipherView()
    let encrypted = try await ciphers.encrypt(cipherView: view)
    let initial = try await ciphers.decrypt(cipher: encrypted.cipher)
    guard initial.name == view.name, initial.login?.password == view.login?.password else {
      throw ProbeFailure.cipherRoundTripFailed
    }
    print("cipher_round_trip=passed")

    crypto.clearUserCryptoKeys()
    do {
      _ = try await crypto.getUserEncryptionKey()
      throw ProbeFailure.keyReadStillAvailable
    } catch ProbeFailure.keyReadStillAvailable {
      throw ProbeFailure.keyReadStillAvailable
    } catch {
      print("retained_key_read=rejected")
    }
    do {
      _ = try await ciphers.decrypt(cipher: encrypted.cipher)
      throw ProbeFailure.decryptStillAvailable
    } catch ProbeFailure.decryptStillAvailable {
      throw ProbeFailure.decryptStillAvailable
    } catch {
      print("retained_cipher_decrypt=rejected")
    }

    let independentView = try await independentCiphers.decrypt(cipher: encrypted.cipher)
    guard independentView.name == view.name, independentView.login?.password == view.login?.password
    else {
      throw ProbeFailure.independentClientLostKeys
    }
    print("independent_client=preserved")

    try await crypto.initializeUserCrypto(req: fixture.request())
    let restored = try await ciphers.decrypt(cipher: encrypted.cipher)
    guard restored.name == view.name, restored.login?.password == view.login?.password else {
      throw ProbeFailure.reinitializationFailed
    }
    print("explicit_reinitialization=passed")
    print("key_clear_proof=passed")
  }
}

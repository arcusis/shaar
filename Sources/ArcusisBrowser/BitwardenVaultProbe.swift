import ChromiumBridge
import Foundation

enum BitwardenVaultFlags {
  static func valid(
    enabled: Bool, bitwarden: Bool, onboardingControl: Bool, fixtureTLS: Bool,
    awaitAbruptTermination: Bool, expectAbruptRecovery: Bool
  ) -> Bool {
    !enabled
      || (bitwarden && onboardingControl && fixtureTLS
        && !awaitAbruptTermination && !expectAbruptRecovery)
  }
}

enum VaultProbeStageAcceptance {
  static func accepts(phase: String, stages: [String: Bool]) -> Bool {
    let required: [String]
    switch phase {
    case "initial":
      required = [
        "store-consent", "onboarding-control", "signed-out-alpha", "signed-out-beta",
        "self-hosted-server-alpha", "self-hosted-server-beta", "account-alpha-login",
        "account-beta-login", "initial-locked-alpha", "initial-locked-beta",
        "initial-unlock-alpha", "initial-unlock-beta", "initial-restart-locked-alpha",
        "initial-restart-locked-beta",
        "account-alpha-identity-matches", "account-beta-identity-matches",
        "account-alpha-cross-profile-mismatch", "account-beta-cross-profile-mismatch",
        "shared-alpha-space-retains-profile", "separate-profile-isolation",
      ]
    case "restart":
      required = [
        "restart-locked-alpha", "restart-locked-beta", "restart-unlock-alpha",
        "restart-unlock-beta", "account-alpha-login", "account-beta-login",
        "account-alpha-identity-matches", "account-beta-identity-matches",
        "account-alpha-cross-profile-mismatch", "account-beta-cross-profile-mismatch",
        "shared-alpha-space-retains-profile", "separate-profile-isolation",
      ]
    default:
      return false
    }
    return required.allSatisfy { stages[$0] == true }
  }
}

/// Credential-safe helpers for driving the vendor-owned popup through ordinary UI controls.
@MainActor
final class BitwardenVaultProbe {
  struct UIState {
    let emailFields: Int
    let passwordFields: Int
    let loginButton: Bool
    let continueButton: Bool
    let unlockButton: Bool
    let vaultVisible: Bool
    let loginPrompt: Bool
    let skipPrompt: Bool
    let introCarousel: Bool
    let regionSelector: Bool
    let selfHostedBaseURLField: Bool
    let saveButton: Bool
    let lockNowButton: Bool
    let accountIdentityMatches: Bool
  }

  private let runtime: ARCChromiumRuntime
  private let popupID: String

  init(runtime: ARCChromiumRuntime, popupID: String) {
    self.runtime = runtime
    self.popupID = popupID
  }

  func state(expectedAccount: String? = nil) async -> UIState? {
    let expectedLiteral = expectedAccount.flatMap(Self.jsonLiteral) ?? "null"
    let script = """
      (()=>{const b=[...document.querySelectorAll('button,[role="button"]')];
        const labels=b.map(x=>(x.innerText||x.getAttribute('aria-label')||'').trim().toLowerCase());
        const t=(document.body?.innerText||'').toLowerCase();
        const expected=\(expectedLiteral);
        return {emailFields:[...document.querySelectorAll('input[type="email"]')].length,
          passwordFields:[...document.querySelectorAll('input[type="password"]')].length,
          loginButton:labels.some(x=>x==='log in'||x==='login'),
          continueButton:labels.some(x=>x==='continue'),
          unlockButton:labels.some(x=>x==='unlock'),
          vaultVisible:t.includes('my vault')||t.includes('new item'),
          loginPrompt:t.includes('log in'),skipPrompt:t.includes('default password manager'),
          introCarousel:location.hash==='#/intro-carousel',
          regionSelector:b.some(x=>/^(bitwarden\\.com|bitwarden\\.eu)$/.test((x.innerText||'').trim().toLowerCase())),
          selfHostedBaseURLField:!!document.querySelector('#self_hosted_env_settings_form_input_base_url'),
          saveButton:labels.includes('save'),
          lockNowButton:labels.includes('lock now'),
          accountIdentityMatches:expected!==null&&t.includes(expected.toLowerCase())};})()
      """
    guard let object = await evaluate(script) as? [String: Any],
      let emailFields = object["emailFields"] as? Int,
      let passwordFields = object["passwordFields"] as? Int
    else { return nil }
    return UIState(
      emailFields: emailFields, passwordFields: passwordFields,
      loginButton: object["loginButton"] as? Bool == true,
      continueButton: object["continueButton"] as? Bool == true,
      unlockButton: object["unlockButton"] as? Bool == true,
      vaultVisible: object["vaultVisible"] as? Bool == true,
      loginPrompt: object["loginPrompt"] as? Bool == true,
      skipPrompt: object["skipPrompt"] as? Bool == true,
      introCarousel: object["introCarousel"] as? Bool == true,
      regionSelector: object["regionSelector"] as? Bool == true,
      selfHostedBaseURLField: object["selfHostedBaseURLField"] as? Bool == true,
      saveButton: object["saveButton"] as? Bool == true,
      lockNowButton: object["lockNowButton"] as? Bool == true,
      accountIdentityMatches: object["accountIdentityMatches"] as? Bool == true)
  }

  func fillEmail(_ value: String) async -> Bool { await fill(type: "email", value: value) }
  func fillPassword(_ value: String) async -> Bool { await fill(type: "password", value: value) }
  func configureSelfHostedServer(_ url: URL) async -> Bool {
    guard let region = await visibleRegionButton(), await click(region),
      await click("self-hosted"), await waitFor({ $0.selfHostedBaseURLField }),
      await fill(
        selector: "#self_hosted_env_settings_form_input_base_url", value: url.absoluteString),
      await waitFor({ $0.saveButton }), await click("Save")
    else { return false }
    return await waitFor({ $0.emailFields > 0 || $0.passwordFields > 0 })
  }

  private func visibleRegionButton() async -> String? {
    let script = """
      (()=>{const x=[...document.querySelectorAll('button,[role="button"]')]
        .map(e=>(e.innerText||'').trim().toLowerCase())
        .find(t=>t==='bitwarden.com'||t==='bitwarden.eu');return x||''})()
      """
    guard let value = await evaluate(script) as? String else { return nil }
    return value.isEmpty ? nil : value
  }

  func click(_ title: String) async -> Bool {
    await withCheckedContinuation { continuation in
      runtime.clickProbePopupID(popupID, buttonTitle: title) {
        continuation.resume(returning: $0)
      }
    }
  }

  func waitFor(
    _ predicate: (UIState) -> Bool, seconds: Int = 45, expectedAccount: String? = nil
  ) async -> Bool {
    for _ in 0..<(seconds * 4) {
      if let current = await state(expectedAccount: expectedAccount), predicate(current) {
        return true
      }
      try? await Task.sleep(for: .milliseconds(250))
    }
    return false
  }

  private func fill(type: String, value: String) async -> Bool {
    await fill(selector: "input[type=\"\(type)\"]", value: value)
  }

  private func fill(selector: String, value: String) async -> Bool {
    guard let encoded = try? JSONSerialization.data(withJSONObject: [value]),
      let json = String(data: encoded, encoding: .utf8),
      let first = json.firstIndex(of: "["), let last = json.lastIndex(of: "]")
    else { return false }
    let literal = String(json[json.index(after: first)..<last])
    guard let selectorLiteral = Self.jsonLiteral(selector) else { return false }
    let script = """
      (()=>{const e=document.querySelector(\(selectorLiteral));if(!e)return false;
        const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value')?.set;
        if(!setter)return false;setter.call(e,\(literal));
        e.dispatchEvent(new Event('input',{bubbles:true}));
        e.dispatchEvent(new Event('change',{bubbles:true}));return true;})()
      """
    return await evaluate(script) as? Bool == true
  }

  private func evaluate(_ script: String) async -> Any? {
    let value: String? = await withCheckedContinuation { continuation in
      runtime.evaluateProbePopupID(popupID, script: script) { continuation.resume(returning: $0) }
    }
    guard let data = value?.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  }

  private static func jsonLiteral(_ value: String) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: [value]),
      let json = String(data: data, encoding: .utf8),
      let first = json.firstIndex(of: "["), let last = json.lastIndex(of: "]")
    else { return nil }
    return String(json[json.index(after: first)..<last])
  }
}

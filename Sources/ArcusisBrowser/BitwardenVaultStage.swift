import Foundation

struct BitwardenVaultStageSignals: Equatable {
  enum Classification: String {
    case readyToContinue = "ready-to-continue"
    case emailFormAbsent = "email-form-absent"
    case continueDisabled = "continue-disabled"
    case emailFormInvalid = "email-form-invalid"
    case passwordRouteArrived = "password-route-arrived"
    case passwordRouteTimedOut = "password-route-timed-out"
  }

  let emailFormPresent: Bool
  let continueButtonEnabled: Bool
  let emailFormValid: Bool
  let passwordRouteArrived: Bool
  let classification: Classification

  init(
    emailFormPresent: Bool,
    continueButtonEnabled: Bool,
    emailFormValid: Bool,
    passwordRouteArrived: Bool,
    timedOut: Bool
  ) {
    self.emailFormPresent = emailFormPresent
    self.continueButtonEnabled = continueButtonEnabled
    self.emailFormValid = emailFormValid
    self.passwordRouteArrived = passwordRouteArrived

    if passwordRouteArrived {
      classification = .passwordRouteArrived
    } else if !emailFormPresent {
      classification = .emailFormAbsent
    } else if !continueButtonEnabled {
      classification = .continueDisabled
    } else if !emailFormValid {
      classification = .emailFormInvalid
    } else if timedOut {
      classification = .passwordRouteTimedOut
    } else {
      classification = .readyToContinue
    }
  }

  init?(object: [String: Any], timedOut: Bool = false) {
    guard let emailFormPresent = object["emailFormPresent"] as? Bool,
      let continueButtonEnabled = object["continueButtonEnabled"] as? Bool,
      let emailFormValid = object["emailFormValid"] as? Bool,
      let passwordRouteArrived = object["passwordRouteArrived"] as? Bool
    else { return nil }
    self.init(
      emailFormPresent: emailFormPresent,
      continueButtonEnabled: continueButtonEnabled,
      emailFormValid: emailFormValid,
      passwordRouteArrived: passwordRouteArrived,
      timedOut: timedOut)
  }
}

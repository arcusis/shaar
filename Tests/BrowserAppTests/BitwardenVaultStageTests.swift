import Testing

@testable import ArcusisBrowser

@Test func bitwardenVaultStageSignalsClassifyContinueReadiness() {
  let ready = BitwardenVaultStageSignals(
    emailFormPresent: true, continueButtonEnabled: true, emailFormValid: true,
    passwordRouteArrived: false, timedOut: false)
  #expect(ready.classification == .readyToContinue)

  let disabled = BitwardenVaultStageSignals(
    emailFormPresent: true, continueButtonEnabled: false, emailFormValid: true,
    passwordRouteArrived: false, timedOut: false)
  #expect(disabled.classification == .continueDisabled)

  let invalid = BitwardenVaultStageSignals(
    emailFormPresent: true, continueButtonEnabled: true, emailFormValid: false,
    passwordRouteArrived: false, timedOut: false)
  #expect(invalid.classification == .emailFormInvalid)
}

@Test func bitwardenVaultStageSignalsClassifyMissingAndTimedOutRoutes() {
  let missingForm = BitwardenVaultStageSignals(
    emailFormPresent: false, continueButtonEnabled: false, emailFormValid: false,
    passwordRouteArrived: false, timedOut: true)
  #expect(missingForm.classification == .emailFormAbsent)

  let timedOut = BitwardenVaultStageSignals(
    emailFormPresent: true, continueButtonEnabled: true, emailFormValid: true,
    passwordRouteArrived: false, timedOut: true)
  #expect(timedOut.classification == .passwordRouteTimedOut)

  let arrived = BitwardenVaultStageSignals(
    emailFormPresent: false, continueButtonEnabled: false, emailFormValid: false,
    passwordRouteArrived: true, timedOut: true)
  #expect(arrived.classification == .passwordRouteArrived)
}

@Test func bitwardenVaultStageSignalsRejectIncompleteObjects() {
  #expect(BitwardenVaultStageSignals(object: ["emailFormPresent": true]) == nil)
}

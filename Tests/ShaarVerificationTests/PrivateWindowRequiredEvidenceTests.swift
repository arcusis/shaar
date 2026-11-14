// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@MainActor @Suite struct PrivateWindowRequiredEvidenceTests {
  @Test func requiredCheckNamesAreUniqueForEarlyFailureReports() {
    #expect(Set(PrivateWindowProbe.checkNames).count == PrivateWindowProbe.checkNames.count)
  }

  private func completeChecks() -> [String: Bool] {
    Dictionary(uniqueKeysWithValues: PrivateWindowProbe.checkNames.map { ($0, true) })
  }

  @Test func allRequiredChecksMustPass() {
    #expect(PrivateWindowProbe.evidencePassed(checks: completeChecks(), expectedFailures: [:]))
    for name in PrivateWindowProbe.checkNames {
      var failed = completeChecks()
      failed[name] = false
      #expect(!PrivateWindowProbe.evidencePassed(checks: failed, expectedFailures: [:]))
    }
    var missing = completeChecks()
    missing.removeValue(forKey: PrivateWindowProbe.checkNames[0])
    #expect(!PrivateWindowProbe.evidencePassed(checks: missing, expectedFailures: [:]))
  }

  @Test func privateHostMustRemainAttachedAfterTabClose() {
    #expect(
      PrivateWindowProbe.checkNames.contains(
        "productPrivateHostRemainsAttachedAfterTabClose"))
  }

  @Test func onlyTheDocumentedSecondPrivateTabFailureIsAllowed() {
    var checks = completeChecks()
    checks["productSecondPrivateTabRenders"] = false
    let expected = "Issue #417: second private tab may display a black page."
    #expect(
      PrivateWindowProbe.evidencePassed(
        checks: checks, expectedFailures: ["productSecondPrivateTabRenders": expected]))
    #expect(
      !PrivateWindowProbe.evidencePassed(
        checks: checks, expectedFailures: ["productSecondPrivateTabRenders": "different issue"]))

    checks["productFirstPrivateTabRenders"] = false
    #expect(
      !PrivateWindowProbe.evidencePassed(
        checks: checks, expectedFailures: ["productSecondPrivateTabRenders": expected]))
  }
}

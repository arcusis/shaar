import Foundation
import Testing

@testable import BrowserCore

private func binding(
  profile: UUID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
  vault: UUID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
  account: UUID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
  authority: URL = URL(string: "https://vault.example")!
) -> PasswordAuthenticationBinding {
  PasswordAuthenticationBinding(
    profileID: profile, vaultID: vault, accountID: account, authority: authority)
}

@Test @MainActor func replacementRevokesPriorAttempt() {
  let gate = PasswordAuthenticationGate(binding: binding())
  let old = gate.beginAttempt()!
  let current = gate.beginAttempt()!
  var published: [String] = []

  #expect(!gate.commit(old) { published.append("old") })
  #expect(gate.commit(current) { published.append("current") })
  #expect(published == ["current"])
}

@Test @MainActor func disableRejectsLateResultAndReenableAllowsFreshAttempt() {
  let gate = PasswordAuthenticationGate(binding: binding())
  let late = gate.beginAttempt()!
  gate.setEnabled(false)
  var published = false

  #expect(gate.beginAttempt() == nil)
  #expect(!gate.commit(late) { published = true })
  #expect(!published)
  gate.setEnabled(true)
  #expect(gate.commit(gate.beginAttempt()!) { published = true })
  #expect(published)
}

@Test @MainActor func changedAuthorityRevokesOldBinding() {
  let gate = PasswordAuthenticationGate(binding: binding())
  let old = gate.beginAttempt()!
  gate.rebind(to: binding(authority: URL(string: "https://self-hosted.example")!))
  let fresh = gate.beginAttempt()!
  var published: [String] = []

  #expect(!gate.commit(old) { published.append("old") })
  #expect(gate.commit(fresh) { published.append("fresh") })
  #expect(published == ["fresh"])
}

@Test @MainActor func rebindingToSameContextPreservesAttempt() {
  let context = binding()
  let gate = PasswordAuthenticationGate(binding: context)
  let attempt = gate.beginAttempt()!
  gate.rebind(to: context)
  var published = false

  #expect(gate.commit(attempt) { published = true })
  #expect(published)
}

@Test @MainActor func foreignGateCannotCommitAttempt() {
  let first = PasswordAuthenticationGate(binding: binding())
  let second = PasswordAuthenticationGate(binding: binding())
  let attempt = first.beginAttempt()!
  var published = false

  #expect(!second.commit(attempt) { published = true })
  #expect(!published)
}

@Test @MainActor func profilesHaveIndependentOwnership() {
  let profileA = PasswordAuthenticationGate(binding: binding())
  let profileB = PasswordAuthenticationGate(
    binding: binding(profile: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!))
  let attemptA = profileA.beginAttempt()!
  let attemptB = profileB.beginAttempt()!
  profileA.setEnabled(false)
  var publishedB = false

  #expect(!profileA.commit(attemptA) {})
  #expect(profileB.commit(attemptB) { publishedB = true })
  #expect(publishedB)
}

@Test @MainActor func reentrantPublicationCanStartSuccessor() {
  let gate = PasswordAuthenticationGate(binding: binding())
  let first = gate.beginAttempt()!
  var successor: PasswordAuthenticationGate.Attempt?
  var firstPublished = false
  var successorPublished = false

  #expect(
    gate.commit(first) {
      firstPublished = true
      gate.rebind(to: binding(authority: URL(string: "https://replacement.example")!))
      successor = gate.beginAttempt()
    })
  #expect(firstPublished)
  #expect(successor != nil)
  #expect(gate.commit(successor!) { successorPublished = true })
  #expect(successorPublished)
}

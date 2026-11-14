// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite("Renderer recovery checkpoint identity")
struct RendererRecoveryProbeTests {
  @Test func recoveryRequiresANonblankPriorDocumentIdentity() {
    let identity = RendererRecoveryIdentity(
      spaceID: UUID(), tabID: UUID(), profileID: UUID(), lastDocument: "document-instance")
    #expect(identity.hasUsableDocumentIdentity)
    #expect(
      !RendererRecoveryIdentity(
        spaceID: identity.spaceID, tabID: identity.tabID, profileID: identity.profileID,
        lastDocument: ""
      ).hasUsableDocumentIdentity)
    #expect(
      !RendererRecoveryIdentity(
        spaceID: identity.spaceID, tabID: identity.tabID, profileID: identity.profileID,
        lastDocument: " \n\t "
      ).hasUsableDocumentIdentity)
  }

  @Test func recoveryMustReturnToThePriorDocumentURL() {
    let original = "http://localhost:41000/renderer-crash-account"
    #expect(RendererRecoveryIdentity.recoveryRetainsDocumentURL(original: original, restored: original))
    #expect(
      !RendererRecoveryIdentity.recoveryRetainsDocumentURL(
        original: original, restored: "http://localhost:41000/light"))
    #expect(!RendererRecoveryIdentity.recoveryRetainsDocumentURL(original: original, restored: nil))
  }
}

// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite struct BitwardenStoreButtonValidationTests {
  @Test func installButtonMustBePresentAndEnabled() {
    #expect(BitwardenStoreButtonValidation.hasEnabledInstallButton(in: [
      "buttons": [["text": "Add to Chrome", "disabled": false]],
    ]))
    #expect(BitwardenStoreButtonValidation.hasEnabledInstallButton(in: [
      "buttons": [["text": "add to chrome"]],
    ]))
    #expect(!BitwardenStoreButtonValidation.hasEnabledInstallButton(in: [
      "buttons": [["text": "Add to Chrome", "disabled": true]],
    ]))
    #expect(!BitwardenStoreButtonValidation.hasEnabledInstallButton(in: [
      "buttons": [["text": "Open extension"]],
    ]))
    #expect(!BitwardenStoreButtonValidation.hasEnabledInstallButton(in: ["buttons": NSNull()]))
  }
}

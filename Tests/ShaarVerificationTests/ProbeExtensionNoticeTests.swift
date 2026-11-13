// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite @MainActor struct ProbeExtensionNoticeTests {
  @Test func popupFailureRequiresANewNonNilNotice() {
    #expect(ProbeExtensionFixture.hasNewNotice(since: nil, currentNotice: "Extension failed"))
    #expect(!ProbeExtensionFixture.hasNewNotice(since: "Prior", currentNotice: "Prior"))
    #expect(!ProbeExtensionFixture.hasNewNotice(since: "Prior", currentNotice: nil))
    #expect(ProbeExtensionFixture.hasNewNotice(since: nil, currentNotice: ""))
  }
}

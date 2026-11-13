// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import ScreenCaptureKit
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct DesktopCapturePickerTests {
  @Test func tabOnlyRequestsSkipScreenAccessAndKeepTheCurrentTabSelectable() async throws {
    let store = BrowserStore()
    store.perform(.open(try #require(URL(string: "https://meet.example/call"))))
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let profileID = store.session.selectedSpace.profileID
    let requestID = UUID().uuidString
    let request = try #require(
      DesktopCaptureRequest(payload: [
        "id": requestID,
        "profileID": profileID.uuidString,
        "tabID": tab.id.uuidString,
        "pageURL": tab.url.absoluteString,
        "origin": "https://meet.example",
        "frameID": "0123456789abcdef0123456789abcdef",
        "sourceTypes": ["tab"],
      ]))
    #expect(store.requestDesktopCapture(request))

    var preflightCalls = 0
    var permissionCalls = 0
    var contentCalls = 0
    let picker = DesktopCapturePicker(
      request: request,
      store: store,
      hasScreenRecordingAccess: {
        preflightCalls += 1
        return false
      },
      requestScreenRecordingAccess: {
        permissionCalls += 1
        return false
      },
      shareableContent: {
        contentCalls += 1
        throw CocoaError(.fileReadUnknown)
      }
    )
    await picker.loadSources()

    #expect(preflightCalls == 0)
    #expect(permissionCalls == 0)
    #expect(contentCalls == 0)
    var decision: String?
    store.onDesktopCaptureDecision = { _, sourceID in decision = sourceID }
    let tabToken = "tab:\(tab.id.uuidString):0"
    store.resolveDesktopCapture(request.id, sourceID: tabToken)
    #expect(decision == tabToken)
  }
}

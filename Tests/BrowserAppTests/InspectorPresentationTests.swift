// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ArcusisBrowser

@MainActor
private final class ManualToastScheduler: InspectorToastScheduling {
  @MainActor
  final class Timeout: InspectorToastCancellation {
    private let clear: @MainActor () -> Void
    private(set) var cancelled = false

    init(clear: @escaping @MainActor () -> Void) { self.clear = clear }

    func cancel() { cancelled = true }

    // Model a callback already queued when cancellation arrives.
    func fire() { clear() }
  }

  private(set) var timeouts: [Timeout] = []

  func schedule(_ clear: @escaping @MainActor () -> Void) -> any InspectorToastCancellation {
    let timeout = Timeout(clear: clear)
    timeouts.append(timeout)
    return timeout
  }
}

@Suite @MainActor struct InspectorPresentationTests {
  @Test func startsWithExpectedSectionAndMenuState() {
    let presentation = InspectorPresentation()

    #expect(presentation.collapsedSections == ["Code:Layout", "Code:Element overrides", "Code:Tools"])
    #expect(presentation.codeSections == ["Code:Styles"])
    #expect(!presentation.copyMenuOpen)
    #expect(presentation.toast == nil)
  }

  @Test func replacingCopyToastCancelsEarlierTimeout() {
    let scheduler = ManualToastScheduler()
    let presentation = InspectorPresentation(toastScheduler: scheduler)
    presentation.copied("CSS selector")
    #expect(scheduler.timeouts.count == 1)
    presentation.copied("XPath")
    #expect(scheduler.timeouts.count == 2)
    #expect(scheduler.timeouts[0].cancelled)
    scheduler.timeouts[0].fire()
    #expect(presentation.toast == "Copied XPath to clipboard")
    scheduler.timeouts[1].fire()
    #expect(presentation.toast == nil)

    presentation.copied("XPath")
    presentation.dismiss()
    #expect(scheduler.timeouts[2].cancelled)
    scheduler.timeouts[2].fire()
    #expect(presentation.toast == nil)
  }
}

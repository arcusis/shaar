import Foundation
import Testing

@testable import ArcusisBrowser

@Suite
struct SpaceSwipeNavigationTests {
  @Test func handledSwipeConsumesEventAndCyclesInExpectedDirection() {
    var offsets: [Int] = []

    let previous = SpaceSwipeNavigationDecision.route(
      deltaX: 2, deltaY: 0, eventBelongsToWindow: true,
      commandPressed: false, modalOwnsInput: false
    ) { offsets.append($0) }
    let next = SpaceSwipeNavigationDecision.route(
      deltaX: -2, deltaY: 0, eventBelongsToWindow: true,
      commandPressed: false, modalOwnsInput: false
    ) { offsets.append($0) }

    #expect(previous == .consumed)
    #expect(next == .consumed)
    #expect(offsets == [-1, 1])
  }

  @Test func ignoredSwipeForwardsEventWithoutChangingSpace() {
    let cases: [(CGFloat, CGFloat, Bool, Bool, Bool)] = [
      (0, 2, true, false, false),
      (2, 2, true, false, false),
      (2, 0, false, false, false),
      (2, 0, true, true, false),
      (2, 0, true, false, true),
    ]
    var actions = 0

    for (deltaX, deltaY, belongs, command, modal) in cases {
      let result = SpaceSwipeNavigationDecision.route(
        deltaX: deltaX, deltaY: deltaY, eventBelongsToWindow: belongs,
        commandPressed: command, modalOwnsInput: modal
      ) { _ in actions += 1 }
      #expect(result == .forwarded)
    }

    #expect(actions == 0)
  }

  @MainActor
  @Test func monitorOwnershipInstallsOnceAndCleansUpAtLastDetachOrInvalidation() {
    final class Client {}
    var installs = 0
    var removals = 0
    let ownership = SpaceSwipeMonitorOwnership(
      install: { installs += 1 }, remove: { removals += 1 })
    let first = Client()
    let second = Client()

    ownership.attach(first)
    ownership.attach(first)
    ownership.attach(second)
    #expect(installs == 1)
    #expect(removals == 0)

    ownership.detach(first)
    #expect(removals == 0)
    #expect(ownership.hasClients)

    ownership.detach(second)
    ownership.detach(second)
    #expect(removals == 1)
    #expect(!ownership.hasClients)

    ownership.attach(first)
    ownership.invalidate()
    ownership.invalidate()
    #expect(installs == 2)
    #expect(removals == 2)
  }

  @MainActor
  @Test func destroyedClientReleasesMonitorOwnership() {
    final class Client {}
    var installs = 0
    var removals = 0
    let ownership = SpaceSwipeMonitorOwnership(
      install: { installs += 1 }, remove: { removals += 1 })
    var client: Client? = Client()

    ownership.attach(client!)
    #expect(installs == 1)
    #expect(ownership.hasClients)

    client = nil

    #expect(!ownership.hasClients)
    #expect(removals == 1)
  }
}

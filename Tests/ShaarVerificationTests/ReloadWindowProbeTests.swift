// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite @MainActor struct ReloadWindowProbeTests {
  @Test func newWindowLinksMustProduceANewTab() {
    let source = UUID()
    let oldTab = UUID()
    let newTab = UUID()
    let owner = UUID()
    let otherOwner = UUID()
    let prior: Set<UUID> = [source, oldTab]

    #expect(
      !ReloadWindowProbe.isDestinationCandidate(
        tabID: source, sourceID: source, prior: prior,
        candidateOwnerID: owner, ownerID: owner, requiresNewTab: true))
    #expect(
      !ReloadWindowProbe.isDestinationCandidate(
        tabID: oldTab, sourceID: source, prior: prior,
        candidateOwnerID: owner, ownerID: owner, requiresNewTab: true))
    #expect(
      ReloadWindowProbe.isDestinationCandidate(
        tabID: newTab, sourceID: source, prior: prior,
        candidateOwnerID: owner, ownerID: owner, requiresNewTab: true))
    #expect(
      ReloadWindowProbe.isDestinationCandidate(
        tabID: source, sourceID: source, prior: prior,
        candidateOwnerID: owner, ownerID: owner, requiresNewTab: false))
    #expect(
      !ReloadWindowProbe.isDestinationCandidate(
        tabID: newTab, sourceID: source, prior: prior,
        candidateOwnerID: otherOwner, ownerID: owner, requiresNewTab: true))
  }

  @Test func plainLinkReusesItsSourceAndPopupGestureCreatesOneNewTab() {
    let source = UUID()
    let destination = UUID()
    #expect(
      ReloadWindowProbe.hasExpectedDestinationTabCount(
        name: "plain", createdTabs: [], source: source, destination: source))
    #expect(
      !ReloadWindowProbe.hasExpectedDestinationTabCount(
        name: "plain", createdTabs: [destination], source: source, destination: destination))
    #expect(
      !ReloadWindowProbe.hasExpectedDestinationTabCount(
        name: "plain", createdTabs: [], source: source, destination: destination))
    #expect(
      ReloadWindowProbe.hasExpectedDestinationTabCount(
        name: "target blank", createdTabs: [destination], source: source,
        destination: destination))
    #expect(
      !ReloadWindowProbe.hasExpectedDestinationTabCount(
        name: "target blank", createdTabs: [source, destination], source: source,
        destination: destination))
  }

  @Test func aPopupGestureMustCreateExactlyOneDestinationTab() {
    let destination = UUID()
    #expect(
      ReloadWindowProbe.hasExpectedDestinationTabCount(
        name: "target blank", createdTabs: [destination], source: UUID(),
        destination: destination))
    #expect(
      !ReloadWindowProbe.hasExpectedDestinationTabCount(
        name: "target blank", createdTabs: [], source: UUID(), destination: destination))
    #expect(
      !ReloadWindowProbe.hasExpectedDestinationTabCount(
        name: "target blank", createdTabs: [destination, UUID()], source: UUID(),
        destination: destination))
    #expect(
      !ReloadWindowProbe.hasExpectedDestinationTabCount(
        name: "target blank", createdTabs: [UUID()], source: UUID(), destination: destination))
  }

  @Test func newWindowNavigationRequiresASeparateDestinationAndRetainedSource() {
    let sourceID = UUID()
    let destinationID = UUID()
    #expect(
      ReloadWindowProbe.newWindowDestinationPassed(
        sourceTabID: sourceID, destinationTabID: destinationID,
        sourceHref: "http://127.0.0.1:41000/cross-site-a",
        destinationHref: "http://localhost:41000/cross-site-b",
        marker: "Cross-site destination loaded"))
    #expect(
      !ReloadWindowProbe.newWindowDestinationPassed(
        sourceTabID: sourceID, destinationTabID: sourceID,
        sourceHref: "http://localhost:41000/cross-site-b",
        destinationHref: "http://localhost:41000/cross-site-b",
        marker: "Cross-site destination loaded"))
    #expect(
      !ReloadWindowProbe.newWindowDestinationPassed(
        sourceTabID: sourceID, destinationTabID: destinationID,
        sourceHref: "http://127.0.0.1:41000/cross-site-a",
        destinationHref: "http://localhost:41000/cross-site-b",
        marker: ""))
  }

  @Test func failedPageCheckOnlyConsidersTheSourceAndDestinationTabs() {
    let source = UUID()
    let destination = UUID()
    let unrelated = UUID()
    let tested: Set<UUID> = [source, destination]

    #expect(
      ReloadWindowProbe.hasNoRendererFailures(on: tested, failureTabIDs: [unrelated]))
    #expect(
      !ReloadWindowProbe.hasNoRendererFailures(on: tested, failureTabIDs: [source]))
    #expect(
      !ReloadWindowProbe.hasNoRendererFailures(on: tested, failureTabIDs: [destination]))
  }
}

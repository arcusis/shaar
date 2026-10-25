import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor
final class BrowserSettingsLayoutTests: XCTestCase {
  func testCompactProfileLayoutWithPopulatedFixturesFitsWindow() {
    let profileID = UUID()
    let selectedProfileID = Binding<UUID?>(get: { profileID }, set: { _ in })
    let sidebarInitiallyVisible = Binding<Bool>(get: { true }, set: { _ in })
    let selectedSearchEngine = Binding<String>(get: { "duckDuckGo" }, set: { _ in })
    let view = BrowserSettingsView(
      profiles: [BrowserSettingsProfile(id: profileID, name: "Work", spaceCount: 1)],
      searchEngines: [
        BrowserSettingsChoice(id: "google", title: "Google"),
        BrowserSettingsChoice(id: "duckDuckGo", title: "DuckDuckGo"),
        BrowserSettingsChoice(id: "bing", title: "Bing"),
      ], selectedProfileID: selectedProfileID, sidebarInitiallyVisible: sidebarInitiallyVisible,
      selectedSearchEngine: selectedSearchEngine, initialSection: .profiles)

    let host = layout(view, size: NSSize(width: 620, height: 500))

    XCTAssertEqual(host.bounds.size, NSSize(width: 620, height: 500))
    XCTAssertGreaterThanOrEqual(host.fittingSize.width, 600)
    XCTAssertGreaterThanOrEqual(host.fittingSize.height, 440)
    XCTAssertEqual(selectedProfileID.wrappedValue, profileID)
    XCTAssertEqual(selectedSearchEngine.wrappedValue, "duckDuckGo")
    XCTAssertTrue(sidebarInitiallyVisible.wrappedValue)
  }

  func testNormalGeneralLayoutFitsWindow() {
    let selectedProfileID = Binding<UUID?>(get: { nil }, set: { _ in })
    let sidebarInitiallyVisible = Binding<Bool>(get: { false }, set: { _ in })
    let selectedSearchEngine = Binding<String>(get: { "google" }, set: { _ in })
    let view = BrowserSettingsView(
      profiles: [], searchEngines: [], selectedProfileID: selectedProfileID,
      sidebarInitiallyVisible: sidebarInitiallyVisible, selectedSearchEngine: selectedSearchEngine,
      initialSection: .general)

    let host = layout(view, size: NSSize(width: 720, height: 650))

    XCTAssertEqual(host.bounds.size, NSSize(width: 720, height: 650))
    XCTAssertGreaterThanOrEqual(host.fittingSize.width, 600)
    XCTAssertGreaterThanOrEqual(host.fittingSize.height, 440)
    XCTAssertFalse(sidebarInitiallyVisible.wrappedValue)
  }

  func testMissingSelectedProfileDoesNotSubstituteProfileOrChoice() {
    let missingProfileID = UUID()
    let selectedProfileID = Binding<UUID?>(get: { missingProfileID }, set: { _ in })
    let sidebarInitiallyVisible = Binding<Bool>(get: { true }, set: { _ in })
    let selectedSearchEngine = Binding<String>(get: { "bing" }, set: { _ in })
    let view = BrowserSettingsView(
      profiles: [BrowserSettingsProfile(id: UUID(), name: "Work", spaceCount: 2)],
      searchEngines: [BrowserSettingsChoice(id: "google", title: "Google")],
      selectedProfileID: selectedProfileID, sidebarInitiallyVisible: sidebarInitiallyVisible,
      selectedSearchEngine: selectedSearchEngine, initialSection: .profiles)

    let host = layout(view, size: NSSize(width: 620, height: 500))

    XCTAssertEqual(host.bounds.size, NSSize(width: 620, height: 500))
    XCTAssertEqual(selectedProfileID.wrappedValue, missingProfileID)
    XCTAssertEqual(selectedSearchEngine.wrappedValue, "bing")
  }

  func testEmptyProfilesAndChoicesLayoutAtMinimumPreferredSize() {
    let selectedProfileID = Binding<UUID?>(get: { nil }, set: { _ in })
    let sidebarInitiallyVisible = Binding<Bool>(get: { true }, set: { _ in })
    let selectedSearchEngine = Binding<String>(get: { "google" }, set: { _ in })
    let view = BrowserSettingsView(
      profiles: [], searchEngines: [], selectedProfileID: selectedProfileID,
      sidebarInitiallyVisible: sidebarInitiallyVisible, selectedSearchEngine: selectedSearchEngine,
      initialSection: .profiles)

    let host = layout(view, size: NSSize(width: 620, height: 500))

    XCTAssertEqual(host.bounds.size, NSSize(width: 620, height: 500))
    XCTAssertGreaterThanOrEqual(host.fittingSize.width, 600)
    XCTAssertGreaterThanOrEqual(host.fittingSize.height, 440)
  }

  func testCompactProfileEditorLayoutFitsWindow() {
    let view = ProfileNameEditor(
      title: "Rename Profile", initialName: "Work", onCancel: {}, onSave: { _ in true })

    let host = layout(view, size: NSSize(width: 440, height: 220))

    XCTAssertEqual(host.bounds.size, NSSize(width: 440, height: 220))
    XCTAssertLessThanOrEqual(host.fittingSize.width, 440)
    XCTAssertLessThanOrEqual(host.fittingSize.height, 220)
  }

  private func layout<V: View>(_ view: V, size: NSSize) -> NSHostingView<V> {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    return host
  }
}

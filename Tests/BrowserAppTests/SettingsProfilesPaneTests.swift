import AppKit
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Test @MainActor func profilePaneMasterDetailFitsLightAndDarkAppearances() {
  let id = UUID()
  let selectedProfileID = Binding<UUID?>(get: { id }, set: { _ in })
  let view = BrowserSettingsView(
    profiles: [
      BrowserSettingsProfile(
        id: id, name: "Work",
        spaces: [BrowserSettingsSpace(id: UUID(), name: "Research", symbol: "book")],
        extensionCount: 2)
    ],
    searchEngines: [BrowserSettingsChoice(id: "google", title: "Google")],
    selectedProfileID: selectedProfileID,
    sidebarInitiallyVisible: .constant(true), selectedSearchEngine: .constant("google"),
    initialSection: .profiles)
  let host = NSHostingView(rootView: view)
  host.frame = NSRect(x: 0, y: 0, width: 720, height: 560)

  for appearance in [NSAppearance(named: .aqua), NSAppearance(named: .darkAqua)] {
    host.appearance = appearance
    host.layoutSubtreeIfNeeded()
    #expect(host.bounds.width == 720)
    #expect(host.bounds.height == 560)
    #expect(host.fittingSize.width >= 600)
    #expect(host.fittingSize.height >= 440)
  }
}

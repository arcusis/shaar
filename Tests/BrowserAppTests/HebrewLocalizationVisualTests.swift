// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Security
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor
final class HebrewLocalizationVisualTests: XCTestCase {
  private var language: BrowserLanguage { BrowserLanguage.currentLaunchLanguage }
  private var output: URL {
    URL(
      fileURLWithPath: "build/Verification/localization-visuals/\(language.localeIdentifier)",
      isDirectory: true)
  }

  override func setUpWithError() throws {
    let arguments = ProcessInfo.processInfo.arguments
    guard let selectionIndex = arguments.firstIndex(of: "-BrowserLanguage.selection"),
      arguments.indices.contains(selectionIndex + 1)
    else {
      throw XCTSkip("Run through test-localization.py with isolated launch-language selection")
    }
    let selected = BrowserLanguage.currentLaunchLanguage
    XCTAssertEqual(arguments[selectionIndex + 1], selected.rawValue)
    let directory = URL(
      fileURLWithPath: "build/Verification/localization-visuals/\(selected.localeIdentifier)",
      isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func testBrowserSidebarAndCommandTAtWidthsThemesAndSidebarStates() throws {
    var session = BrowserSession.fresh()
    let url = URL(string: "https://example.test/localized?profile=Latin")!
    let tabID = try XCTUnwrap(session.open(url))
    XCTAssertTrue(session.updateTab(tabID, url: url, title: "דף בדיקה · example.test"))
    let store = BrowserStore(session: session)
    store.launcherActions = LauncherActions(available: { LauncherCommands.catalog }, run: { _ in })
    for (theme, appearance) in [(ColorScheme.light, NSAppearance.Name.aqua), (.dark, .darkAqua)] {
      for (width, visible) in [(CGFloat(760), true), (CGFloat(1200), true), (CGFloat(760), false)] {
        store.sidebarIsVisible = visible
        let size = NSSize(width: width, height: 640)
        let suffix =
          "\(Int(width))-\(visible ? "shown" : "hidden")-\(theme == .dark ? "dark" : "light")"
        let sidebar = BrowserWindow(store: store)
          .environment(\.colorScheme, theme)
          .frame(width: width, height: size.height)
        let sidebarBitmap = try capture(
          sidebar, name: "sidebar-\(suffix).png", size: size, appearance: appearance)
        if !visible { assertHiddenSidebarLeavesFullPage(sidebarBitmap) }

        store.showCommand()
        store.commandFilter = .actions
        let actionTitles = store.commandSections.results.compactMap { result -> String? in
          if case .command = result.action { return result.title }
          return nil
        }
        XCTAssertFalse(actionTitles.isEmpty)
        if language.isRightToLeft {
          XCTAssertTrue(
            actionTitles.contains { title in
              title.unicodeScalars.contains { (0x0590...0x05FF).contains(Int($0.value)) }
            }, "Command-T Actions need localized Hebrew titles")
          XCTAssertTrue(
            store.commandSections.results.contains {
              $0.subtitle.contains("\u{2066}⌘N\u{2069}")
            }, "Keyboard modifiers and Latin keys keep LTR order inside Hebrew descriptions")
        }
        let command = BrowserWindow(store: store)
          .environment(\.colorScheme, theme)
          .transaction { $0.disablesAnimations = true }
          .frame(width: width, height: size.height)
        try capture(command, name: "command-t-\(suffix).png", size: size, appearance: appearance)
        if theme == .light {
          assertCommandPanelOccupiesPageCard(
            try VisualCapture.renderOffscreen(
              command, size: size, appearance: appearance,
              to: output.appending(path: "geometry-\(suffix).png")),
            sidebarVisible: visible)
        }
        if width == 760 && visible {
          let query = "חיפוש example.test / Shaar"
          store.commandFilter = nil
          store.commandQuery = query
          try capture(
            BrowserWindow(store: store).environment(\.colorScheme, theme),
            name: "command-t-mixed-\(theme == .dark ? "dark" : "light").png",
            size: size, appearance: appearance)
          XCTAssertEqual(store.commandQuery, query)
        }
        store.dismissCommand()
      }
    }
  }

  func testSettingsAndOnboardingRenderHebrewInLightAndDark() throws {
    let id = UUID()
    for (theme, appearance) in [(ColorScheme.light, NSAppearance.Name.aqua), (.dark, .darkAqua)] {
      for section in BrowserSettingsSection.allCases {
        let settings = BrowserSettingsView(
          profiles: [
            BrowserSettingsProfile(
              id: id, name: "אישי",
              spaces: [BrowserSettingsSpace(id: UUID(), name: "מרחב אישי", symbol: "house")])
          ],
          searchEngines: [BrowserSettingsChoice(id: "google", title: "Google")],
          selectedProfileID: .constant(id), sidebarInitiallyVisible: .constant(true),
          selectedSearchEngine: .constant("google"), initialSection: section
        )
        .environment(\.colorScheme, theme)
        let sectionName = section == .general ? "settings" : "settings-\(section.rawValue)"
        try capture(
          settings, name: "\(sectionName)-\(theme == .dark ? "dark" : "light").png",
          size: NSSize(width: 820, height: 620), appearance: appearance)
      }

      for step in ProfileOnboardingStep.allCases {
        let model = Self.onboardingModel(at: step)
        XCTAssertEqual(model.step, step)
        let onboarding = ProfileOnboardingView(model: model).environment(\.colorScheme, theme)
        try capture(
          onboarding,
          name: "onboarding-\(step)-\(theme == .dark ? "dark" : "light").png",
          size: ProfileOnboardingView.size, appearance: appearance)
      }
    }
  }

  func testSiteControlCenterMiniPlayerAndPictureInPicture() throws {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(),
      url: URL(string: "https://example.test")!)
    let model = SiteControlsModel(target: target, backend: MockSiteControlsBackend())
    let extensions = ExtensionManagerModel(profileID: target.profileID, extensions: [])
    let panel = SiteControlsPanel(
      model: model, extensions: extensions, profileName: "אישי",
      actions: SiteControlsPanelActions(
        runExtension: { _ in }, addExtensions: {},
        showCertificate: {}, showDeveloperTools: {}, close: {}))
    let state = MediaSessionState(
      playbackState: .playing, title: "קטע בדיקה", artist: "אמן",
      actions: [.pause, .previousTrack, .nextTrack], volume: 0.35)
    let item = MiniPlayerItem(tabID: UUID(), pageTitle: "דף בדיקה", favicon: nil, state: state)
    for (theme, appearance) in [(ColorScheme.light, NSAppearance.Name.aqua), (.dark, .darkAqua)] {
      let scheme = theme == .dark ? "dark" : "light"
      try capture(
        panel.environment(\.colorScheme, theme), name: "site-control-center-\(scheme).png",
        size: NSSize(width: 320, height: 720), appearance: appearance)
      try capture(
        SidebarMediaPlayer(volumeIsVisible: true, item: item, onSelect: {}, onCommand: { _ in })
          .environment(\.colorScheme, theme),
        name: "mini-player-\(scheme).png",
        size: NSSize(width: BrowserChromeLayout.sidebarWidth, height: 100),
        appearance: appearance)

      let size = NSSize(width: 356, height: 200)
      let pip = PictureInPictureControlsView(frame: NSRect(origin: .zero, size: size))
      pip.presentation = .init(isPlaying: true, isLive: false)
      pip.setControlsShown(true, animated: false)
      XCTAssertEqual(
        pip.button(.playPause)?.accessibilityLabel(),
        BrowserLocalization.string("Pause", table: "Panels", language: language))
      let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size), styleMask: [], backing: .buffered,
        defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: appearance)
      // Authored video backdrop makes the transparent controls comparable at fixed 1x.
      let video = NSView(frame: pip.frame)
      video.wantsLayer = true
      video.layer?.backgroundColor =
        NSColor(
          srgbRed: 0.14, green: 0.24, blue: 0.34, alpha: 1
        ).cgColor
      video.addSubview(pip)
      window.contentView = video
      defer { window.close() }
      pip.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      XCTAssertFalse(window.isVisible)
      let back = try XCTUnwrap(pip.button(.backToTab))
      let close = try XCTUnwrap(pip.button(.close))
      XCTAssertEqual(back.frame.minX > close.frame.minX, language.isRightToLeft)
      XCTAssertLessThan(
        try XCTUnwrap(pip.button(.skipBack)).frame.midX,
        try XCTUnwrap(pip.button(.playPause)).frame.midX)
      XCTAssertLessThan(
        try XCTUnwrap(pip.button(.playPause)).frame.midX,
        try XCTUnwrap(pip.button(.skipForward)).frame.midX)
      let bitmap = try VisualCapture.render(
        video, to: output.appending(path: "picture-in-picture-\(scheme).png"))
      assertNonblank(bitmap, size: size)
    }
  }

  func testPagerAndSidebarToggleRenderAtLogicalPositions() throws {
    let store = BrowserStore(session: .fresh())
    let first = store.session.spaces[0].id
    store.perform(.space(store.session.spaces[1].id))
    let state = SpacePagerState()
    for offset in [CGFloat(0), 50] {
      state.offset = offset
      let view = SpacePager(store: store, state: state, reduceMotion: true) { space in
        (space.id == first ? Color.red : Color.blue)
          .overlay { Text(space.name).foregroundStyle(.white) }
      }
      .frame(width: 200, height: 120)
      .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
      .transaction { $0.disablesAnimations = true }
      let bitmap = try VisualCapture.renderOffscreen(
        view, size: NSSize(width: 200, height: 120), appearance: .aqua,
        to: output.appending(
          path: offset == 0 ? "space-pager-selected.png" : "space-pager-drag.png"))
      XCTAssertEqual(bitmap.pixelsWide, 200)
      XCTAssertEqual(bitmap.pixelsHigh, 120)
      for x in [25, 175] {
        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: 20)?.usingColorSpace(.deviceRGB))
        let red = offset != 0 && (language.isRightToLeft ? x == 175 : x == 25)
        XCTAssertGreaterThan(
          red ? color.redComponent - color.blueComponent : color.blueComponent - color.redComponent,
          0.3, "Selected Space and drag offset must occupy the correct physical region")
      }
    }

    for fullScreen in [false, true] {
      let view = TitlebarSidebarToggle(store: store)
        .frame(width: 200, height: 36)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .environment(\.browserWindowIsFullScreen, fullScreen)
        .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
      let bitmap = try VisualCapture.renderOffscreen(
        view, size: NSSize(width: 200, height: 36), appearance: .aqua,
        to: output.appending(path: "sidebar-toggle-\(fullScreen ? "fullscreen" : "windowed").png"))
      let columns = (0..<200).filter { x in
        (0..<36).contains { y in
          guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
            return false
          }
          return max(color.redComponent, color.greenComponent, color.blueComponent) < 0.8
        }
      }
      let left = try XCTUnwrap(columns.first)
      let right = try XCTUnwrap(columns.last)
      let leading =
        fullScreen
        ? BrowserChromeLayout.fullScreenToggleLeading : BrowserChromeLayout.titlebarToggleLeading
      let center = leading + 14
      XCTAssertEqual(
        CGFloat(left + right) / 2, language.isRightToLeft ? 200 - center : center, accuracy: 2)
    }
  }

  @discardableResult private func capture<V: View>(
    _ view: V, name: String, size: NSSize, appearance: NSAppearance.Name
  ) throws -> NSBitmapImageRep {
    let root = view.frame(width: size.width, height: size.height)
      .background(Color(nsColor: .windowBackgroundColor))
      .environment(\.locale, Locale(identifier: language.localeIdentifier))
      .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
      .transaction { $0.disablesAnimations = true }
    let bitmap = try VisualCapture.renderOffscreen(
      root, size: size, appearance: appearance,
      to: output.appending(path: name))
    assertNonblank(bitmap, size: size)
    let settings = BrowserLocalization.string("Settings…", table: "Shell", language: language)
    XCTAssertEqual(settings, language.isRightToLeft ? "הגדרות…" : "Settings…")
    return bitmap
  }

  private static func onboardingModel(at step: ProfileOnboardingStep) -> ProfileOnboardingModel {
    var pendingSignIn: ((ConnectedAccount?) -> Void)?
    let model = ProfileOnboardingModel(
      actions: ProfileOnboardingActions(
        connect: { _, _, completion in pendingSignIn = completion }, stopConnecting: {},
        create: { $0.id }, close: { _ in }))
    model.name = "פרופיל Test"
    model.color = ProfileColorChoice(tint: .ocean)
    model.symbol = "briefcase.fill"
    guard step != .details else { return model }
    model.continueToNext()
    if step == .microsoft {
      model.skip()
      model.connect(.microsoft)
      return model
    }
    model.connect(.google)
    pendingSignIn?(
      ConnectedAccount(provider: .google, email: "alex@example.test", name: "Alex Example"))
    guard step != .google else { return model }
    model.continueToNext()
    return model
  }

  private func assertNonblank(
    _ bitmap: NSBitmapImageRep, size: NSSize,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(bitmap.pixelsWide, Int(size.width), file: file, line: line)
    XCTAssertEqual(bitmap.pixelsHigh, Int(size.height), file: file, line: line)
    var colors = Set<String>()
    var opaque = 0
    let sampleStep = 4
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: sampleStep) {
      for x in stride(from: 0, to: bitmap.pixelsWide, by: sampleStep) {
        guard let rgba = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        if rgba.alphaComponent > 0.9 { opaque += 1 }
        colors.insert(
          "\(Int(rgba.redComponent * 255)):\(Int(rgba.greenComponent * 255)):\(Int(rgba.blueComponent * 255))"
        )
      }
    }
    XCTAssertGreaterThan(
      opaque, bitmap.pixelsWide * bitmap.pixelsHigh / sampleStep / sampleStep / 2,
      "capture must have opaque rendered coverage", file: file, line: line)
    XCTAssertGreaterThan(
      colors.count, 16, "capture must show structured UI pixels", file: file, line: line)
  }

  private func assertCommandPanelOccupiesPageCard(
    _ bitmap: NSBitmapImageRep, sidebarVisible: Bool
  ) {
    // The light panel stays white while its backdrop dims the page and sidebar.
    let columns = (0..<bitmap.pixelsWide).filter { x in
      guard
        let color = bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2)?
          .usingColorSpace(.deviceRGB)
      else { return false }
      return min(color.redComponent, color.greenComponent, color.blueComponent) > 0.95
    }
    guard let left = columns.first, let right = columns.last else {
      return XCTFail("Command-T panel pixels missing")
    }
    let sidebar = sidebarVisible ? BrowserChromeLayout.sidebarWidth : 0
    let pageLeft = language.isRightToLeft ? CGFloat(8) : sidebar + 8
    let pageWidth = CGFloat(bitmap.pixelsWide) - sidebar - 16
    let panelWidth = min(BrowserChromeLayout.preferredCommandWidth, pageWidth)
    let expectedLeft = pageLeft + (pageWidth - panelWidth) / 2
    XCTAssertEqual(CGFloat(left), expectedLeft, accuracy: 2)
    XCTAssertEqual(CGFloat(right + 1), expectedLeft + panelWidth, accuracy: 2)
  }

  private func assertHiddenSidebarLeavesFullPage(_ bitmap: NSBitmapImageRep) {
    let y = bitmap.pixelsHigh / 2
    guard let reference = bitmap.colorAt(x: 40, y: y)?.usingColorSpace(.deviceRGB)
    else { return XCTFail("Page pixels unavailable") }
    // Inspect the whole row: an incorrectly mirrored offset can leave the sidebar in its center.
    for x in stride(from: 40, to: bitmap.pixelsWide - 40, by: 20)
    where abs(x - bitmap.pixelsWide / 2) > 70 {
      guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
      let difference =
        abs(reference.redComponent - color.redComponent)
        + abs(reference.greenComponent - color.greenComponent)
        + abs(reference.blueComponent - color.blueComponent)
      XCTAssertLessThan(difference, 0.015, "Hidden sidebar must clear page column \(x)")
    }
  }
}

@MainActor
private final class MockSiteControlsBackend: SiteControlBackend {
  func security(of target: SiteControlTarget) -> SiteSecurity { .secure }
  func permissionValues(for target: SiteControlTarget) async throws -> [SitePermission:
    SitePermissionValue]
  {
    [.camera: .ask, .microphone: .block]
  }
  func setPermission(_ permission: SitePermission, allowed: Bool, for target: SiteControlTarget)
    async throws
  {}
  func perform(_ action: SiteAction, for target: SiteControlTarget) async throws {}
  func certificateChain(for target: SiteControlTarget) async throws -> [SecCertificate] { [] }
}

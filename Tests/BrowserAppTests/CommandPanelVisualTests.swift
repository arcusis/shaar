import AppKit
import BrowserCore
import SwiftUI
import Vision
import XCTest

@testable import ArcusisBrowser

private struct CommandPanelBoundsKey: PreferenceKey {
  static let defaultValue = CGRect.zero
  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    let next = nextValue()
    if !next.isEmpty { value = next }
  }
}

@MainActor
final class CommandPanelVisualTests: XCTestCase {
  nonisolated override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(
      SidebarVisualCaptureSupport.enabled,
      "Command panel capture requires explicitly enabled GitHub Actions macOS CI")
    _ = try SidebarVisualCaptureSupport.prepare()
  }

  private final class Measurements { var panel = CGRect.zero }
  private struct PairCapture {
    let url: URL
    let panel: CGRect
    let size: NSSize
  }

  func testHostedPanelInSyntheticPageViewports() async throws {
    let root = try SidebarVisualCaptureSupport.prepare()
    var failures: [String] = []
    var captures: [String: [String: PairCapture]] = [:]
    var attempts = 0
    for scheme in [ColorScheme.light, .dark] {
      for minimum in [false, true] {
        for sidebar in [false, true] {
          for page in ["white", "dark"] {
            attempts += 1
            let key =
              "\(scheme == .dark ? "dark" : "light")-\(minimum ? "minimum" : "regular")-\(sidebar ? "sidebar" : "no-sidebar")-standard"
            do {
              captures[key, default: [:]][page] = try await capture(
                root: root, key: key, page: page, scheme: scheme, minimum: minimum,
                sidebar: sidebar, longQuery: false)
            } catch { failures.append(key + "-" + page + ": " + String(describing: error)) }
          }
        }
      }
      for page in ["white", "dark"] {
        attempts += 1
        let key = "\(scheme == .dark ? "dark" : "light")-minimum-sidebar-long-query"
        do {
          captures[key, default: [:]][page] = try await capture(
            root: root, key: key, page: page, scheme: scheme, minimum: true,
            sidebar: true, longQuery: true)
        } catch { failures.append(key + "-" + page + ": " + String(describing: error)) }
      }
    }
    for (key, pair) in captures.sorted(by: { $0.key < $1.key }) {
      do {
        guard let white = pair["white"], let dark = pair["dark"] else {
          throw CommandPanelCaptureError.missingPair
        }
        let difference = try interiorDifference(white, dark)
        let passed = difference <= 0.02
        try SidebarVisualCaptureSupport.record(
          root: root,
          entry: [
            "check": "paired-interior-samples", "scenario": key,
            "status": passed ? "passed" : "failed", "maxRGBDifference": difference,
            "scope": "three selected interior pixels only; not a whole-panel opacity proof",
            "componentOnly": true, "physicalInput": false, "visualAcceptance": false,
          ])
        if !passed {
          failures.append(key + ": sampled panel interior changed across page backgrounds")
        }
      } catch {
        failures.append(key + ": " + String(describing: error))
        try SidebarVisualCaptureSupport.record(
          root: root,
          entry: [
            "check": "paired-interior-samples", "scenario": key, "status": "failed",
            "error": String(describing: error),
          ])
      }
    }
    XCTAssertEqual(attempts, 20)
    XCTAssertEqual(captures.count, 10)
    XCTAssertTrue(failures.isEmpty, "Command panel capture failures: \(failures)")
  }

  private func capture(
    root: URL, key: String, page: String, scheme: ColorScheme, minimum: Bool,
    sidebar: Bool, longQuery: Bool
  ) async throws -> PairCapture {
    let file = "command-panel-\(key)-on-\(page).png"
    do {
      let store = try makeStore(longQuery: longQuery)
      let initial = store.session
      let results = store.results
      if !longQuery {
        guard results.contains(where: { if case .tab = $0.action { true } else { false } }),
          results.contains(where: { if case .space = $0.action { true } else { false } })
        else { throw CommandPanelCaptureError.missingFixtureResults }
      }
      guard !results.contains(where: { $0.title.localizedCaseInsensitiveContains("contact team") })
      else { throw CommandPanelCaptureError.unexpectedContactResult }
      let size = minimum ? NSSize(width: 760, height: 520) : NSSize(width: 1_100, height: 720)
      let left = sidebar ? BrowserChromeLayout.sidebarWidth : 10
      let viewport = CGRect(x: left, y: 45, width: size.width - left - 10, height: size.height - 55)
      let expected = BrowserChromeLayout.commandPanelFrame(in: viewport, resultCount: results.count)
      let resultsHeight = BrowserChromeLayout.commandResultsHeight(
        resultCount: results.count, availableHeight: expected.height)
      let measurements = Measurements()
      let view = ZStack(alignment: .topLeading) {
        Color(nsColor: .windowBackgroundColor)
        (page == "white" ? Color.white : Color.black)
          .frame(width: viewport.width, height: viewport.height)
          .position(x: viewport.midX, y: viewport.midY)
        CommandPanel(store: store, resultsHeight: resultsHeight)
          .environment(\.colorScheme, scheme)
          .frame(width: expected.width)
          .fixedSize(horizontal: false, vertical: true)
          .background {
            GeometryReader { geometry in
              Color.clear.preference(
                key: CommandPanelBoundsKey.self,
                value: geometry.frame(in: .named("commandCapture")))
            }
          }
          .position(x: expected.midX, y: expected.midY)
      }
      .frame(width: size.width, height: size.height)
      .coordinateSpace(name: "commandCapture")
      .onPreferenceChange(CommandPanelBoundsKey.self) { measurements.panel = $0 }
      let mounted = try MountedChromeSidebar(
        view: view, size: size, appearance: scheme == .dark ? .darkAqua : .aqua)
      defer { mounted.close() }
      let hasBounds = await mounted.waitUntil({ !measurements.panel.isEmpty })
      let image = root.appendingPathComponent(file)
      let queryToken = longQuery ? "research" : "Atlas"
      let resultToken = longQuery ? "Open in Atlas Space" : "Notes"
      _ = try await mounted.capture(to: image, requiredText: [queryToken, resultToken])
      let actual = measurements.panel
      let fits =
        hasBounds && actual.minX >= viewport.minX - 0.5
        && actual.maxX <= viewport.maxX + 0.5 && actual.minY >= viewport.minY - 0.5
        && actual.maxY <= viewport.maxY + 0.5 && abs(actual.width - expected.width) <= 0.5
        && abs(actual.midX - viewport.midX) <= 0.5 && abs(actual.midY - viewport.midY) <= 0.5
        && (!sidebar || actual.midX > size.width / 2 + 10)
      let visible = try queryAndResultVisible(
        image, size: size, panel: actual, queryToken: queryToken, resultToken: resultToken)
      let unchanged = store.session == initial
      let passed = fits && visible && unchanged
      try SidebarVisualCaptureSupport.record(
        root: root,
        entry: [
          "check": "command-viewport-layout-and-text", "file": file, "scenario": key,
          "status": passed ? "passed" : "failed", "page": page, "sidebarShown": sidebar,
          "viewport": rect(viewport), "expectedPanel": rect(expected), "actualPanel": rect(actual),
          "resultCount": results.count, "resultsHeight": Double(resultsHeight),
          "queryAndResultVisible": visible, "sessionUnchanged": unchanged,
          "componentOnly": true, "physicalInput": false, "visualAcceptance": false,
        ])
      guard passed else { throw CommandPanelCaptureError.layoutOrText }
      return PairCapture(url: image, panel: actual, size: size)
    } catch {
      try SidebarVisualCaptureSupport.record(
        root: root,
        entry: [
          "check": "command-viewport-layout-and-text", "file": file, "scenario": key,
          "status": "failed", "error": String(describing: error),
        ])
      throw error
    }
  }

  private func makeStore(longQuery: Bool) throws -> BrowserStore {
    let profileID = UUID(uuidString: "42000000-0000-0000-0000-000000000001")!
    let spaceID = UUID(uuidString: "42000000-0000-0000-0000-000000000002")!
    let tabID = UUID(uuidString: "42000000-0000-0000-0000-000000000003")!
    let longTabID = UUID(uuidString: "42000000-0000-0000-0000-000000000004")!
    let profile = BrowserProfile(id: profileID, name: "Sample Profile")
    let space = BrowserSpace(
      id: spaceID, profileID: profileID,
      name: "Atlas Space " + String(repeating: "extended workspace ", count: 4),
      symbol: "globe", tint: .lavender,
      tabs: [
        BrowserTab(
          id: tabID, url: URL(string: "https://example.test/notes")!, title: "Atlas Notes"),
        BrowserTab(
          id: longTabID, url: URL(string: "https://example.test/research")!,
          title: "Atlas " + String(repeating: "long research context ", count: 5)),
      ], selectedTabID: tabID)
    let session = try BrowserSession(profiles: [profile], spaces: [space], selectedSpaceID: spaceID)
    let store = BrowserStore(sessionFile: nil, session: session)
    store.commandQuery = longQuery ? String(repeating: "research ", count: 18) : "Atlas"
    return store
  }

  private func queryAndResultVisible(
    _ url: URL, size: NSSize, panel: CGRect, queryToken: String, resultToken: String
  ) throws -> Bool {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(url: url).perform([request])
    var queryVisible = false
    var resultVisible = false
    for observation in request.results ?? [] {
      guard let text = observation.topCandidates(1).first?.string else { continue }
      if text.localizedCaseInsensitiveContains("contact team") {
        throw CommandPanelCaptureError.unexpectedContactResult
      }
      let x = observation.boundingBox.midX * size.width
      let y = (1 - observation.boundingBox.midY) * size.height
      guard x >= panel.minX, x <= panel.maxX, y >= panel.minY, y <= panel.maxY else { continue }
      if y < panel.minY + 70, text.range(of: queryToken, options: .caseInsensitive) != nil {
        queryVisible = true
      }
      if y >= panel.minY + 70, text.range(of: resultToken, options: .caseInsensitive) != nil {
        resultVisible = true
      }
    }
    return queryVisible && resultVisible
  }

  private func interiorDifference(_ first: PairCapture, _ second: PairCapture) throws -> Double {
    let dataA = try Data(contentsOf: first.url)
    let dataB = try Data(contentsOf: second.url)
    guard first.size == second.size,
      abs(first.panel.minX - second.panel.minX) <= 0.5,
      abs(first.panel.midY - second.panel.midY) <= 0.5,
      let a = NSBitmapImageRep(data: dataA),
      let b = NSBitmapImageRep(data: dataB),
      a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh
    else { throw CommandPanelCaptureError.invalidPair }
    var difference: CGFloat = 0
    for offset in [-20.0, 0, 20.0] {
      let x = Int((first.panel.minX + 4) * CGFloat(a.pixelsWide) / first.size.width)
      let y = Int((first.panel.midY + offset) * CGFloat(a.pixelsHigh) / first.size.height)
      guard x >= 0, x < a.pixelsWide, y >= 0, y < a.pixelsHigh,
        let colorA = a.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
        let colorB = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
      else { throw CommandPanelCaptureError.invalidPair }
      let red = abs(colorA.redComponent - colorB.redComponent)
      let green = abs(colorA.greenComponent - colorB.greenComponent)
      let blue = abs(colorA.blueComponent - colorB.blueComponent)
      difference = max(difference, max(red, max(green, blue)))
    }
    return Double(difference)
  }

  private func rect(_ value: CGRect) -> [String: Double] {
    [
      "x": Double(value.minX), "y": Double(value.minY),
      "width": Double(value.width), "height": Double(value.height),
    ]
  }
}

private enum CommandPanelCaptureError: Error {
  case missingFixtureResults, unexpectedContactResult, layoutOrText, missingPair, invalidPair
}

import AppKit
import BrowserCore
import SwiftUI
import Vision
import XCTest

@testable import ArcusisBrowser

private struct SpaceEditorBoundsKey: PreferenceKey {
  static let defaultValue = CGRect.zero
  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    let next = nextValue()
    if !next.isEmpty { value = next }
  }
}

@MainActor
final class SpaceEditorVisualTests: XCTestCase {
  nonisolated override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(
      SidebarVisualCaptureSupport.enabled,
      "Space editor capture requires explicitly enabled GitHub Actions macOS CI")
    _ = try SidebarVisualCaptureSupport.prepare()
  }

  private final class Measurements {
    var bounds = CGRect.zero
  }

  private struct Scenario {
    let name: String
    let create: Bool
    let compact: Bool
    let longNames: Bool
    let customRGB: Bool
  }

  func testHostedCreateEditAndSidebarPreview() async throws {
    let root = try SidebarVisualCaptureSupport.prepare()
    let scenarios = [
      Scenario(
        name: "create-regular", create: true, compact: false, longNames: false, customRGB: false),
      Scenario(
        name: "create-compact", create: true, compact: true, longNames: false, customRGB: false),
      Scenario(
        name: "edit-custom-rgb", create: false, compact: false, longNames: false, customRGB: true),
      Scenario(
        name: "edit-long-names", create: false, compact: true, longNames: true, customRGB: true),
    ]
    var failures: [String] = []
    var attempts = 0
    for scheme in [ColorScheme.light, .dark] {
      for scenario in scenarios {
        attempts += 1
        let appearanceName = scheme == .dark ? "dark" : "light"
        let file = "space-editor-\(scenario.name)-\(appearanceName).png"
        do {
          let store = try makeStore(longNames: scenario.longNames, customRGB: scenario.customRGB)
          let original = store.session
          let route: SpaceEditorRoute =
            scenario.create ? .create : .edit(store.session.selectedSpaceID)
          let width: CGFloat = 380
          let size = NSSize(width: width + 24, height: 600)
          let measurements = Measurements()
          let view = SpaceEditor(store: store, route: route)
            .environment(\.colorScheme, scheme)
            .environment(\.horizontalSizeClass, scenario.compact ? .compact : .regular)
            .fixedSize(horizontal: false, vertical: true)
            .background {
              GeometryReader { geometry in
                Color.clear.preference(
                  key: SpaceEditorBoundsKey.self,
                  value: geometry.frame(in: .named("spaceEditorCapture")))
              }
            }
            .padding(.horizontal, 12)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .coordinateSpace(name: "spaceEditorCapture")
            .onPreferenceChange(SpaceEditorBoundsKey.self) { measurements.bounds = $0 }
          let mounted = try MountedChromeSidebar(
            view: view, size: size, appearance: scheme == .dark ? .darkAqua : .aqua)
          defer { mounted.close() }
          let hasBounds = await mounted.waitUntil({ !measurements.bounds.isEmpty })
          let image = root.appendingPathComponent(file)
          let action = scenario.create ? "Create" : "Done"
          _ = try await mounted.capture(to: image, requiredText: ["Cancel", action])
          let bounds = measurements.bounds
          let fits =
            hasBounds && bounds.minX >= 0 && bounds.minY >= 0
            && bounds.maxX <= size.width + 0.5 && bounds.maxY <= size.height + 0.5
            && abs(bounds.width - width) <= 0.5 && bounds.height > 0
          let labels = try visibleActionLabels(
            in: image, editorBounds: bounds, windowHeight: size.height)
          let actionsVisible = labels.contains("cancel") && labels.contains(action.lowercased())
          let unchanged = store.session == original
          let expectedColor =
            scenario.customRGB ? SpaceRGBColor(red: 0x12, green: 0x84, blue: 0xD6) : nil
          let fixtureColorValid = original.selectedSpace.customRGB == expectedColor
          let passed = fits && actionsVisible && unchanged && fixtureColorValid
          try SidebarVisualCaptureSupport.record(
            root: root,
            entry: [
              "file": file, "scenario": scenario.name, "colorScheme": appearanceName,
              "check": "editor-layout-and-actions", "status": passed ? "passed" : "failed",
              "intrinsicWidth": Double(bounds.width),
              "intrinsicHeight": Double(bounds.height), "x": Double(bounds.minX),
              "y": Double(bounds.minY), "windowWidth": Double(size.width),
              "windowHeight": Double(size.height), "fits": fits,
              "actionLabels": labels.sorted(), "requiredAction": action,
              "actionsVisible": actionsVisible, "sessionUnchanged": unchanged,
              "fixtureColorValid": fixtureColorValid,
              "customRGBFixture": scenario.customRGB ? "#1284D6" : "none",
            ])
          if !passed { failures.append(file + ": layout, action labels, or session changed") }
        } catch {
          failures.append(file + ": " + String(describing: error))
          try SidebarVisualCaptureSupport.record(
            root: root,
            entry: [
              "file": file, "scenario": scenario.name, "colorScheme": appearanceName,
              "check": "editor-layout-and-actions", "status": "failed",
              "error": String(describing: error),
            ])
        }
      }
    }
    XCTAssertEqual(attempts, 8)
    XCTAssertTrue(failures.isEmpty, "Space editor visual failures: \(failures)")
  }

  private func makeStore(longNames: Bool, customRGB: Bool) throws -> BrowserStore {
    let profileID = UUID(uuidString: "41000000-0000-0000-0000-000000000001")!
    let spaceID = UUID(uuidString: "41000000-0000-0000-0000-000000000002")!
    let profile = BrowserProfile(
      id: profileID,
      name: longNames
        ? String(repeating: "Research Profile ", count: 5) + "End" : "Synthetic Profile")
    let space = BrowserSpace(
      id: spaceID, profileID: profileID,
      name: longNames
        ? String(repeating: "Workspace Research ", count: 5) + "End" : "Synthetic Space",
      symbol: "globe", tint: .lavender,
      customRGB: customRGB ? SpaceRGBColor(red: 0x12, green: 0x84, blue: 0xD6) : nil)
    let session = try BrowserSession(profiles: [profile], spaces: [space], selectedSpaceID: spaceID)
    return BrowserStore(sessionFile: nil, session: session)
  }

  private func visibleActionLabels(in url: URL, editorBounds: CGRect, windowHeight: CGFloat) throws
    -> Set<String>
  {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(url: url).perform([request])
    var labels: Set<String> = []
    for observation in request.results ?? [] {
      let pointY = (1 - observation.boundingBox.midY) * windowHeight
      guard pointY >= editorBounds.minY + editorBounds.height * 0.65,
        pointY <= editorBounds.maxY + 0.5,
        let text = observation.topCandidates(1).first?.string
      else { continue }
      for token in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
        labels.insert(String(token))
      }
    }
    return labels
  }
}

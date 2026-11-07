// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import ArcusisBrowser

@MainActor
final class ShaarRenderingFixtureTransport: ShaarRenderingTransport {
  var overlayAnswer: Bool?
  var probeCount = 0
  var sent: [[ShaarRenderingCall]] = []

  func probeOverlay(for target: SiteControlTarget) async -> Bool? {
    probeCount += 1
    return overlayAnswer
  }

  func send(_ calls: [ShaarRenderingCall], to target: SiteControlTarget) async throws {
    sent.append(calls)
  }
}

private struct RenderingSampleError: LocalizedError {
  var errorDescription: String?
}

@Suite @MainActor struct ShaarRenderingTests {
  @Test func noOverrideClearsMediaFeatures() {
    let calls = ShaarRenderingCommands.calls(
      colorScheme: .noOverride, motion: .noOverride, cssMedia: .noEmulation,
      paintRects: false, layoutShiftRegions: false, fpsMeter: false,
      overlayAvailable: false)
    #expect(calls.map(\.method) == ["Emulation.setEmulatedMedia"])
    #expect(calls[0].params["media"] as? String == "")
    let features = calls[0].params["features"] as? [[String: String]]
    #expect(features?[0]["name"] == "prefers-color-scheme")
    #expect(features?[0]["value"] == "")
    #expect(features?[1]["name"] == "prefers-reduced-motion")
    #expect(features?[1]["value"] == "")
  }

  @Test func lightReduceAndPrintShareOneMediaCommand() {
    let calls = ShaarRenderingCommands.calls(
      colorScheme: .light, motion: .reduce, cssMedia: .print,
      paintRects: false, layoutShiftRegions: false, fpsMeter: false,
      overlayAvailable: false)
    #expect(calls[0].params["media"] as? String == "print")
    let features = calls[0].params["features"] as? [[String: String]]
    #expect(features?[0]["value"] == "light")
    #expect(features?[1]["value"] == "reduce")
    guard case .media(let media, let colorScheme, let reducedMotion) = calls[0].payload else {
      Issue.record("Expected a media payload")
      return
    }
    #expect(media == "print")
    #expect(colorScheme == "light")
    #expect(reducedMotion == "reduce")
  }

  @Test func darkColorSchemeUsesTheDarkFeatureValue() {
    let calls = ShaarRenderingCommands.calls(
      colorScheme: .dark, motion: .noOverride, cssMedia: .screen,
      paintRects: false, layoutShiftRegions: false, fpsMeter: false,
      overlayAvailable: false)
    let features = calls[0].params["features"] as? [[String: String]]
    #expect(calls[0].params["media"] as? String == "screen")
    #expect(features?[0]["value"] == "dark")
    #expect(features?[1]["value"] == "")
  }

  @Test func overlayCommandsStayOffUntilTheEngineAcceptsThem() {
    let hidden = ShaarRenderingCommands.calls(
      colorScheme: .dark, motion: .noOverride, cssMedia: .noEmulation,
      paintRects: true, layoutShiftRegions: true, fpsMeter: true,
      overlayAvailable: false)
    #expect(hidden.map(\.method) == ["Emulation.setEmulatedMedia"])
    let shown = ShaarRenderingCommands.calls(
      colorScheme: .noOverride, motion: .noOverride, cssMedia: .noEmulation,
      paintRects: true, layoutShiftRegions: false, fpsMeter: true,
      overlayAvailable: true)
    #expect(
      shown.map(\.method) == [
        "Emulation.setEmulatedMedia",
        "Overlay.enable",
        "Overlay.setShowPaintRects",
        "Overlay.setShowLayoutShiftRegions",
        "Overlay.setShowFPSCounter",
      ])
    #expect(shown[1].params.isEmpty)
    #expect(shown[2].params["result"] as? Bool == true)
    #expect(shown[3].params["result"] as? Bool == false)
    #expect(shown[4].params["show"] as? Bool == true)
  }

  @Test func modelSendsMediaWithoutOverlayUntilTheProbeSucceeds() async {
    let fixture = ShaarRenderingFixtureTransport()
    fixture.overlayAnswer = false
    let model = ShaarRenderingModel(target: renderingTarget(), transport: fixture)
    await model.prepare()
    model.colorScheme = .dark
    await model.settled()
    #expect(fixture.probeCount == 1)
    #expect(model.overlayProbeFinished)
    #expect(!model.overlayCommandsAvailable)
    #expect(fixture.sent.count == 1)
    #expect(fixture.sent[0].map(\.method) == ["Emulation.setEmulatedMedia"])
    await model.prepare()
    #expect(fixture.probeCount == 1)
  }

  @Test func paintToggleSendsEveryOverlayFlagAfterTheProbe() async {
    let fixture = ShaarRenderingFixtureTransport()
    fixture.overlayAnswer = true
    let model = ShaarRenderingModel(target: renderingTarget(), transport: fixture)
    await model.prepare()
    model.paintRects = true
    await model.settled()
    let sent = fixture.sent.last
    #expect(
      sent?.map(\.method) == [
        "Emulation.setEmulatedMedia",
        "Overlay.enable",
        "Overlay.setShowPaintRects",
        "Overlay.setShowLayoutShiftRegions",
        "Overlay.setShowFPSCounter",
      ])
    #expect(sent?[2].params["result"] as? Bool == true)
    #expect(sent?[3].params["result"] as? Bool == false)
    #expect(sent?[4].params["show"] as? Bool == false)
  }

  @Test func restoreClearsAnAppliedMediaOverride() async {
    let fixture = ShaarRenderingFixtureTransport()
    let model = ShaarRenderingModel(target: renderingTarget(), transport: fixture)
    model.colorScheme = .dark
    model.motion = .reduce
    model.cssMedia = .print
    await model.settled()
    model.restore()
    await model.settled()
    #expect(model.colorScheme == .noOverride)
    #expect(model.motion == .noOverride)
    #expect(model.cssMedia == .noEmulation)
    guard
      case .media(let media, let colorScheme, let reducedMotion) = fixture.sent.last?.first?.payload
    else {
      Issue.record("Expected a clearing media command")
      return
    }
    #expect(media == "")
    #expect(colorScheme == "")
    #expect(reducedMotion == "")
  }

  @Test func aCommittedNavigationReappliesTheOverride() async {
    let fixture = ShaarRenderingFixtureTransport()
    let first = renderingTarget()
    let model = ShaarRenderingModel(target: first, transport: fixture)
    model.colorScheme = .dark
    await model.settled()
    let next = SiteControlTarget(
      tabID: first.tabID, profileID: first.profileID,
      url: URL(string: "https://example.com/next")!)
    model.updateTarget(next, committed: false)
    await model.settled()
    #expect(fixture.sent.count == 1)
    model.updateTarget(next, committed: true)
    await model.settled()
    #expect(fixture.sent.count == 2)
    #expect(fixture.sent.last?.first?.method == "Emulation.setEmulatedMedia")
  }

  @Test func anUnreadyPageDoesNotFinishTheOverlayProbe() async {
    let fixture = ShaarRenderingFixtureTransport()
    fixture.overlayAnswer = nil
    let model = ShaarRenderingModel(target: renderingTarget(), transport: fixture)
    await model.prepare()
    await model.prepare()
    #expect(fixture.probeCount == 2)
    #expect(!model.overlayProbeFinished)
  }

  @Test func closingTheShellClearsRendering() async {
    let fixture = ShaarRenderingFixtureTransport()
    let shell = ShaarDevToolsModel(target: renderingTarget(), renderingTransport: fixture)
    shell.rendering.colorScheme = .light
    await shell.rendering.settled()
    shell.close()
    await shell.rendering.settled()
    #expect(shell.rendering.colorScheme == .noOverride)
    guard case .media(let media, let colorScheme, _) = fixture.sent.last?.first?.payload else {
      Issue.record("Expected a clearing media command")
      return
    }
    #expect(media == "")
    #expect(colorScheme == "")
  }

  @Test func capabilityClassifierKeepsADeadTargetUnavailable() {
    let unknown = RenderingSampleError(errorDescription: "unknown DevTools capability or command")
    let denied = RenderingSampleError(
      errorDescription: "DevTools command is not allowed for this capability")
    let bridge = RenderingSampleError(errorDescription: "This DevTools command is unavailable.")
    let dropped = RenderingSampleError(errorDescription: "DevTools request failed.")
    let protocolError = RenderingSampleError(errorDescription: "Overlay agent was not enabled")
    let gone = RenderingSampleError(
      errorDescription: "The developer tools target is no longer available.")
    #expect(ShaarRenderingCapability.isMissing(unknown))
    #expect(ShaarRenderingCapability.isMissing(denied))
    #expect(ShaarRenderingCapability.isMissing(bridge))
    #expect(ShaarRenderingCapability.isMissing(dropped))
    #expect(!ShaarRenderingCapability.isMissing(protocolError))
    #expect(!ShaarRenderingCapability.isMissing(gone))
    #expect(ShaarRenderingCapability.targetGone(gone))
    #expect(!ShaarRenderingCapability.targetGone(protocolError))
  }

  @Test func renderingPanelRendersOffscreenForEachState() async throws {
    _ = NSApplication.shared
    #expect(ShaarRenderingColorScheme.allCases.map(\.title) == ["No override", "Light", "Dark"])
    #expect(ShaarRenderingMotion.allCases.map(\.title) == ["No override", "Reduce"])
    #expect(ShaarRenderingCSSMedia.allCases.map(\.title) == ["No emulation", "Screen", "Print"])
    let pending = ShaarRenderingModel(target: renderingTarget())
    let waiting = try VisualCapture.pngOffscreen(
      ShaarRenderingPanel(model: pending), size: NSSize(width: 520, height: 360))
    pending.colorScheme = .dark
    await pending.settled()
    #expect(pending.failure == "Rendering needs a live page.")
    let failed = try VisualCapture.pngOffscreen(
      ShaarRenderingPanel(model: pending), size: NSSize(width: 520, height: 360))
    let blockedTransport = ShaarRenderingFixtureTransport()
    blockedTransport.overlayAnswer = false
    let blocked = ShaarRenderingModel(target: renderingTarget(), transport: blockedTransport)
    await blocked.prepare()
    let note = try VisualCapture.pngOffscreen(
      ShaarRenderingPanel(model: blocked), size: NSSize(width: 520, height: 360))
    let readyTransport = ShaarRenderingFixtureTransport()
    readyTransport.overlayAnswer = true
    let ready = ShaarRenderingModel(target: renderingTarget(), transport: readyTransport)
    await ready.prepare()
    ready.paintRects = true
    ready.layoutShiftRegions = true
    ready.fpsMeter = true
    await ready.settled()
    let enabled = try VisualCapture.pngOffscreen(
      ShaarRenderingPanel(model: ready), size: NSSize(width: 520, height: 360))
    let shellTransport = ShaarRenderingFixtureTransport()
    shellTransport.overlayAnswer = false
    let defaults = UserDefaults(suiteName: "ShaarRendering.\(UUID().uuidString)")!
    let target = renderingTarget()
    let shell = ShaarDevToolsModel(
      target: target, renderingTransport: shellTransport, layoutDefaults: defaults)
    let inspector = InspectorModel(target: target, engine: nil)
    shell.open(inspector: inspector)
    shell.section = .rendering
    await shell.rendering.prepare()
    let panel = try VisualCapture.pngOffscreen(
      ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {}),
      size: NSSize(width: 850, height: 620))
    #expect(!waiting.isEmpty)
    #expect(!failed.isEmpty)
    #expect(!note.isEmpty)
    #expect(!enabled.isEmpty)
    #expect(!panel.isEmpty)
    shell.close()
  }
}

private func renderingTarget() -> SiteControlTarget {
  SiteControlTarget(
    tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/rendering")!)
}

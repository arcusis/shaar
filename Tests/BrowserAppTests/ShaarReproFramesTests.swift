// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import Testing

@testable import ArcusisBrowser

private struct MaskedFrameTransportFixture: ShaarReproTransport {
  let available = true
  let requiresMaskedFrames = true

  func capture(for target: SiteControlTarget, seconds: Int) async throws -> ShaarReproCapture {
    ShaarReproCapture(
      videoMP4: Data(), durationSeconds: seconds,
      dom: ShaarReproDOMNode(tag: "body", text: "Safe", attributes: [:], children: []),
      console: [], network: [],
      environment: ShaarReproEnvironment(
        url: target.url.absoluteString, shaarVersion: "test", engineVersion: "fixture",
        operatingSystem: "macOS", userAgent: "Fixture/1", viewportWidth: 16,
        viewportHeight: 16))
  }
}

@Suite @MainActor struct ShaarReproFramesTests {
  private let target = SiteControlTarget(
    tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com")!)

  @Test func keepsOnlyRecentScopedFrames() throws {
    let ring = ShaarReproFrames()
    let jpeg = try fixtureJPEG()
    let now = Date()
    ring.start(for: target)
    ring.record(jpeg, for: target, at: now.addingTimeInterval(-31))
    ring.record(jpeg, for: target, at: now.addingTimeInterval(-2))
    let other = SiteControlTarget(
      tabID: UUID(), profileID: target.profileID, url: target.url)
    ring.record(jpeg, for: other, at: now)
    ring.record(Data([0xff, 0xd8, 0xff, 0xd9]), for: target, at: now)
    #expect(ring.snapshot(at: now).count == 1)
    ring.stop()
    #expect(ring.snapshot(at: now).isEmpty)
  }

  @Test func encodesRecentFramesAsMP4() async throws {
    let ring = ShaarReproFrames()
    let jpeg = try fixtureJPEG()
    ring.start(for: target)
    ring.record(jpeg, for: target)
    let video = try await ring.encode()
    #expect(video.count >= 12)
    #expect(video[4..<8].elementsEqual(Data("ftyp".utf8)))
  }

  @Test func shellClearsFramesWhenStreamEnds() async throws {
    let jpeg = try fixtureJPEG()
    let inspector = InspectorModel(target: target, engine: nil)
    let transport = ShaarDevToolsFixtureTransport(
      fixture: [], revokeAfterEvents: true, maskedFrames: [jpeg])
    let shell = ShaarDevToolsModel(target: target, transport: transport)
    shell.open(inspector: inspector)
    for _ in 0..<20 { await Task.yield() }
    #expect(shell.repro.frames.snapshot().isEmpty)
    shell.close()
  }

  @Test func shellKeepsMaskedFramesUntilTargetChanges() async throws {
    let jpeg = try fixtureJPEG()
    let inspector = InspectorModel(target: target, engine: nil)
    let shell = ShaarDevToolsModel(
      target: target,
      transport: ShaarDevToolsFixtureTransport(fixture: [], maskedFrames: [jpeg]))
    shell.open(inspector: inspector)
    for _ in 0..<20 where shell.repro.frames.snapshot().isEmpty { await Task.yield() }
    #expect(shell.repro.frames.snapshot().count == 1)
    shell.updateTarget(
      SiteControlTarget(
        tabID: UUID(), profileID: target.profileID, url: target.url))
    #expect(shell.repro.frames.snapshot().isEmpty)
    shell.close()
  }

  @Test func productionCaptureNeedsARecentMaskedFrame() throws {
    let model = ShaarReproModel(target: target, transport: MaskedFrameTransportFixture())
    model.startFrames(for: target)
    #expect(!model.available)
    model.receiveMaskedFrame(try fixtureJPEG())
    #expect(model.available)
    model.stopFrames()
    #expect(!model.available)
  }

  @Test func maskedFrameCaptureWritesEncodedBundle() async throws {
    let model = ShaarReproModel(target: target, transport: MaskedFrameTransportFixture())
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    model.startFrames(for: target)
    model.receiveMaskedFrame(try fixtureJPEG())
    let file = try #require(await model.capture(to: directory))
    let bundle = try await ShaarReproBundle.read(at: file)
    #expect(bundle.videoMP4[4..<8].elementsEqual(Data("ftyp".utf8)))
    #expect(bundle.manifest.durationSeconds == 1)
  }

  private func fixtureJPEG() throws -> Data {
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
        bitsPerPixel: 0))
    return try #require(bitmap.representation(using: .jpeg, properties: [:]))
  }
}

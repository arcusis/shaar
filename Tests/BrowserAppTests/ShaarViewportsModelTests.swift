// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct ShaarViewportsModelTests {
  @Test func fixtureSynchronizesInputAndClearsOnTargetChange() async throws {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/a")!)
    let phone = ShaarViewportFrame(
      id: UUID(), preset: .iphone15Pro, url: target.url, pngData: Data())
    let desktop = ShaarViewportFrame(
      id: UUID(), preset: .desktop, url: target.url, pngData: Data())
    let transport = ShaarViewportsFixtureTransport(frames: [phone, desktop])
    let model = ShaarViewportsModel(target: target, transport: transport)
    model.open()
    for _ in 0..<30 where model.frames.count != 2 { await Task.yield() }
    #expect(model.available && model.frames.count == 2)

    try await model.perform(.click(phone.id, x: 100, y: 250))
    #expect(
      transport.clicks == [
        .init(viewportID: phone.id, x: 100, y: 250),
        .init(viewportID: desktop.id, x: 325, y: 234),
      ])
    try await model.perform(.scroll(desktop.id, deltaX: 0, deltaY: 120))
    #expect(transport.scrolls[phone.id]?.1 == 120)
    #expect(transport.scrolls[desktop.id]?.1 == 120)
    try await model.perform(.navigate(URL(string: "https://example.com/b")!))
    #expect(transport.frames.allSatisfy { $0.url.absoluteString == "https://example.com/b" })
    #expect(transport.targets.allSatisfy { $0 == target })

    try await model.perform(.rotate(phone.id))
    for _ in 0..<30
    where model.frames.first(where: { $0.id == phone.id })?.orientation != .landscape {
      await Task.yield()
    }
    let rotated = try #require(model.frames.first(where: { $0.id == phone.id }))
    #expect(rotated.orientation == .landscape)
    #expect(rotated.contentWidth == 852)
    #expect(rotated.contentHeight == 393)
    let desktopFrame = try #require(model.frames.first(where: { $0.id == desktop.id }))
    #expect(desktopFrame.orientation == .portrait)
    try await model.perform(.click(rotated.id, x: 100, y: 40))
    #expect(
      transport.clicks == [
        .init(viewportID: phone.id, x: 100, y: 40),
        .init(viewportID: desktop.id, x: 150, y: 81),
      ])

    model.updateTarget(
      SiteControlTarget(
        tabID: target.tabID, profileID: target.profileID,
        url: URL(string: "https://example.com/b")!), committed: true)
    #expect(!model.available && model.frames.isEmpty)
    #expect(model.frames.isEmpty)
    model.close()
  }

  @Test func unavailableTransportRejectsActionsAndUnsafeInsets() async throws {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/")!)
    let frame = ShaarViewportFrame(
      id: UUID(), preset: .pixel8, url: target.url, pngData: Data())
    let transport = ShaarViewportsFixtureTransport(frames: [frame])
    let model = ShaarViewportsModel(target: target, transport: transport)
    model.open()
    for _ in 0..<30 where model.frames.isEmpty { await Task.yield() }
    model.close()
    await #expect(throws: ShaarViewportsError.self) {
      try await model.perform(.click(frame.id, x: 10, y: 10))
    }
    model.open()
    for _ in 0..<30 where model.frames.isEmpty { await Task.yield() }
    await #expect(throws: ShaarViewportsError.self) {
      try await model.perform(
        .setSafeArea(frame.id, ShaarViewportInsets(top: 1000, right: 0, bottom: 0, left: 0)))
    }
    #expect(transport.targets.isEmpty)
    model.close()
  }

  @Test func fixtureKeepsAddedDeviceAndInsetsInSync() async throws {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/")!)
    let phone = ShaarViewportFrame(
      id: UUID(), preset: .iphone15Pro, url: target.url, pngData: Data())
    let transport = ShaarViewportsFixtureTransport(frames: [phone])
    let model = ShaarViewportsModel(target: target, transport: transport)
    model.open()
    for _ in 0..<30 where model.frames.isEmpty { await Task.yield() }

    try await model.perform(.add(.pixel8))
    for _ in 0..<30 where model.frames.count != 2 { await Task.yield() }
    let pixel = try #require(model.frames.first(where: { $0.preset == .pixel8 }))
    #expect(pixel.url == phone.url)
    #expect(pixel.safeArea == .init(top: 24, right: 0, bottom: 24, left: 0))

    let insets = ShaarViewportInsets(top: 50, right: 3, bottom: 30, left: 4)
    try await model.perform(.setSafeArea(pixel.id, insets))
    for _ in 0..<30 where model.frames.first(where: { $0.id == pixel.id })?.safeArea != insets {
      await Task.yield()
    }
    #expect(model.frames.first(where: { $0.id == pixel.id })?.safeArea == insets)
    try await model.perform(.remove(pixel.id))
    for _ in 0..<30 where model.frames.count != 1 { await Task.yield() }
    #expect(model.frames.map(\.id) == [phone.id])

    try await model.perform(.add(.ipad))
    for _ in 0..<30 where model.frames.count != 2 { await Task.yield() }
    let ipad = try #require(model.frames.first(where: { $0.preset == .ipad }))
    #expect(ipad.safeArea == .init(top: 24, right: 0, bottom: 20, left: 0))
    #expect(ipad.contentWidth == 820)
    try await model.perform(.rotate(ipad.id))
    for _ in 0..<30
    where model.frames.first(where: { $0.id == ipad.id })?.orientation != .landscape {
      await Task.yield()
    }
    let landscape = try #require(model.frames.first(where: { $0.id == ipad.id }))
    #expect(landscape.orientation == .landscape)
    #expect(landscape.safeArea == .init(top: 0, right: 24, bottom: 0, left: 20))
    #expect(landscape.contentWidth == 1180)
    try await model.perform(.rotate(ipad.id))
    for _ in 0..<30
    where model.frames.first(where: { $0.id == ipad.id })?.orientation != .portrait {
      await Task.yield()
    }
    let restored = try #require(model.frames.first(where: { $0.id == ipad.id }))
    #expect(restored.orientation == .portrait)
    #expect(restored.safeArea == ipad.safeArea)
    model.close()
  }

  @Test func presetsCoverPhoneTabletAndroidAndDesktopWidths() {
    #expect(
      ShaarViewportPreset.allCases.map(\.rawValue) == [
        "iphone15Pro", "ipad", "pixel8", "desktop", "desktop1440",
      ])
    #expect(ShaarViewportPreset.desktop.width == 1280)
    #expect(ShaarViewportPreset.desktop1440.width == 1440)
    #expect(ShaarViewportPreset.desktop1440.height == 900)
    #expect(ShaarViewportPreset.ipad.defaultInsets.bottom == 20)
  }

  @Test func zoomToFitSharesOneScaleAcrossDevices() {
    let content = [
      CGSize(width: 393, height: 852),
      CGSize(width: 820, height: 1180),
      CGSize(width: 1280, height: 800),
    ]
    let fitted = ShaarViewportPreviewLayout.fitScale(
      content: content, available: CGSize(width: 1040, height: 360))
    let fixed = ShaarViewportPreviewLayout.scale(
      fitting: false, content: content, available: CGSize(width: 1040, height: 360))
    #expect(fixed == 0.5)
    #expect(fitted < 0.5)
    #expect(fitted > 0.15)
    let phone = ShaarViewportPreviewLayout.previewSize(
      contentWidth: 393, contentHeight: 852, scale: fitted)
    let desktop = ShaarViewportPreviewLayout.previewSize(
      contentWidth: 1280, contentHeight: 800, scale: fitted)
    let phoneRatio = phone.width / phone.height
    let desktopRatio = desktop.width / desktop.height
    #expect(abs(phoneRatio - (393.0 / 852.0)) < 0.02)
    #expect(abs(desktopRatio - (1280.0 / 800.0)) < 0.02)
    #expect(desktop.width > phone.width)
  }

  @Test func mirroredSchemeHoverTypingAndContactSheet() async throws {
    let png = Data(
      base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/pJkAAAAASUVORK5CYII="
    )!
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/a")!)
    let phone = ShaarViewportFrame(
      id: UUID(), preset: .iphone15Pro, url: target.url, pngData: png)
    let desktop = ShaarViewportFrame(
      id: UUID(), preset: .desktop, url: target.url, pngData: png)
    let transport = ShaarViewportsFixtureTransport(frames: [phone, desktop])
    let model = ShaarViewportsModel(target: target, transport: transport)
    model.open()
    for _ in 0..<30 where model.frames.count != 2 || model.capabilities != .supported {
      await Task.yield()
    }
    #expect(model.capabilities == .supported)

    try await model.perform(.mirrorColorScheme(.dark))
    for _ in 0..<30 where !model.frames.allSatisfy({ $0.colorScheme == .dark }) {
      await Task.yield()
    }
    #expect(model.frames.allSatisfy { $0.colorScheme == .dark })
    try await model.perform(.setColorScheme(phone.id, .light))
    for _ in 0..<30
    where model.frames.first(where: { $0.id == phone.id })?.colorScheme != .light {
      await Task.yield()
    }
    #expect(model.frames.first { $0.id == phone.id }?.colorScheme == .light)
    #expect(model.frames.first { $0.id == desktop.id }?.colorScheme == .dark)
    try await model.perform(.add(.pixel8))
    for _ in 0..<30 where model.frames.count != 3 { await Task.yield() }
    #expect(model.frames.first { $0.preset == .pixel8 }?.colorScheme == .noPreference)

    try await model.perform(.hover(phone.id, x: 10, y: 20))
    #expect(transport.hovers.map(\.viewportID) == [phone.id, desktop.id, model.frames[2].id])
    try await model.perform(.type(desktop.id, text: "Hi"))
    #expect(transport.typed == ["Hi"])
    await #expect(throws: ShaarViewportsError.self) {
      try await model.perform(.type(phone.id, text: ""))
    }
    #expect(!ShaarViewportTyping.isValid(String(repeating: "a", count: 65)))
    #expect(ShaarViewportTyping.isValid("a b"))

    let sheet = try #require(model.contactSheetPNG())
    #expect(sheet.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    let sizes = [CGSize(width: 393, height: 852), CGSize(width: 1280, height: 800)]
    let canvas = ShaarViewportContactSheet.canvasSize(imageSizes: sizes)
    #expect(ShaarViewportContactSheet.displayScale(imageSizes: sizes) < 1)
    #expect(canvas.width <= ShaarViewportContactSheet.maximumWidth)
    #expect(canvas.height <= 780)
    model.close()
    #expect(model.capabilities == ShaarViewportCapabilities())
  }

  @Test func cardWidthKeepsTheDeviceHeaderReadable() {
    let narrow = ShaarViewportPreviewLayout.cardWidth(previewWidth: 80)
    #expect(narrow == ShaarViewportPreviewLayout.minimumCardWidth)
    #expect(ShaarViewportPreviewLayout.cardWidth(previewWidth: 640) == 640)
    let notch = ShaarViewportPreviewLayout.notchSize(previewWidth: 196)
    #expect(notch.width > 40)
    #expect(notch.width < 80)
    #expect(notch.height < notch.width)
  }
}

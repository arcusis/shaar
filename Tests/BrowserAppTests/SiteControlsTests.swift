// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Security
import SwiftUI
import Testing

@testable import ArcusisBrowser

private struct FakeFailure: LocalizedError {
  var errorDescription: String? { "The engine refused." }
}

@MainActor
private final class FakeSiteBackend: SiteControlBackend {
  var securityValue = SiteSecurity.secure
  var values: [SitePermission: SitePermissionValue] = [
    .microphone: .ask, .camera: .block, .location: .ask, .notifications: .ask,
    .popups: .block, .sound: .allow, .autoPictureInPicture: .allow,
  ]
  var failsReads = false
  var failsWrites = false
  var performed: [SiteAction] = []
  var suspendFirstWrite = false
  var writeCount = 0
  var finishFirstWrite: CheckedContinuation<Void, Never>?

  func security(of target: SiteControlTarget) -> SiteSecurity { securityValue }

  func permissionValues(for target: SiteControlTarget) async throws -> [SitePermission:
    SitePermissionValue]
  {
    if failsReads { throw FakeFailure() }
    return values
  }

  func setPermission(_ permission: SitePermission, allowed: Bool, for target: SiteControlTarget)
    async throws
  {
    writeCount += 1
    if writeCount == 1, suspendFirstWrite {
      await withCheckedContinuation { continuation in finishFirstWrite = continuation }
    }
    if failsWrites { throw FakeFailure() }
    values[permission] = allowed ? .allow : .block
  }

  func perform(_ action: SiteAction, for target: SiteControlTarget) async throws {
    if failsWrites { throw FakeFailure() }
    performed.append(action)
  }

  func certificateChain(for target: SiteControlTarget) async throws -> [SecCertificate] {
    throw FakeFailure()
  }
}

@MainActor
private func target(_ address: String) -> SiteControlTarget {
  SiteControlTarget(tabID: UUID(), profileID: UUID(), url: URL(string: address)!)
}

@MainActor @Test func siteControlsLoadAndSavePermissionToggles() async {
  let backend = FakeSiteBackend()
  let model = SiteControlsModel(target: target("https://mail.example/inbox"), backend: backend)
  await model.load()
  #expect(model.permissions == SitePermission.allCases)
  #expect(model.isAllowed(.sound) && !model.isAllowed(.camera))
  await model.setPermission(.camera, allowed: true)
  #expect(model.isAllowed(.camera) && backend.values[.camera] == .allow && model.failure == nil)
}

@MainActor @Test func successfulPermissionRetryClearsStaleFailure() async {
  let backend = FakeSiteBackend()
  let model = SiteControlsModel(target: target("https://mail.example"), backend: backend)
  backend.failsReads = true
  await model.load()
  #expect(model.failure == "The engine refused.")

  backend.failsReads = false
  backend.values[.camera] = .allow
  await model.load()
  #expect(model.isAllowed(.camera))
  #expect(model.failure == nil)
}

@MainActor @Test func rejectedPermissionChangeRestoresTheEngineValue() async {
  let backend = FakeSiteBackend()
  let model = SiteControlsModel(target: target("https://mail.example"), backend: backend)
  await model.load()
  backend.failsWrites = true
  await model.setPermission(.microphone, allowed: true)
  #expect(model.permissionValues[.microphone] == .ask)
  #expect(model.failure == "The engine refused.")
}

@MainActor @Test func siteControlsDoNotOverlapWritesToTheSamePermission() async {
  let backend = FakeSiteBackend()
  backend.suspendFirstWrite = true
  let model = SiteControlsModel(target: target("https://mail.example"), backend: backend)
  await model.load()

  let first = Task { await model.setPermission(.camera, allowed: true) }
  for _ in 0..<100 where backend.finishFirstWrite == nil { await Task.yield() }
  #expect(backend.finishFirstWrite != nil)
  await model.setPermission(.camera, allowed: false)
  #expect(backend.writeCount == 1)
  #expect(model.permissionValues[.camera] == .allow)

  backend.finishFirstWrite?.resume()
  await first.value
  #expect(backend.values[.camera] == .allow)
}

@MainActor @Test func pagesWithoutWebOriginsOfferOnlyReloads() async {
  let backend = FakeSiteBackend()
  backend.securityValue = .unavailable
  let model = SiteControlsModel(target: target("file:///tmp/page.html"), backend: backend)
  await model.load()
  #expect(model.permissions.isEmpty && model.permissionValues.isEmpty)
  #expect(!model.hasCertificate)
  #expect(await model.certificateChain() == nil)
  for action in SiteAction.allCases {
    #expect(model.isAvailable(action) == !action.needsWebOrigin)
  }
  #expect(!(await model.perform(.clearSiteData)))
  #expect(await model.perform(.restartPage))
  #expect(backend.performed == [.restartPage])
}

@MainActor @Test func failedActionKeepsThePanelOpenWithItsReason() async {
  let backend = FakeSiteBackend()
  let model = SiteControlsModel(target: target("http://news.example"), backend: backend)
  #expect(!model.hasCertificate)
  backend.failsWrites = true
  #expect(!(await model.perform(.clearCookiesAndReload)))
  #expect(model.failure == "The engine refused." && model.runningAction == nil)
}

@MainActor @Test func reloadActionsShowTheirMenuShortcuts() {
  #expect(SiteAction.reload.shortcutKeys == "⌘R")
  #expect(SiteAction.hardReload.shortcutKeys == "⇧⌘R")
  #expect(SiteAction.restartPage.shortcutKeys == nil)
  #expect(ShortcutCatalog.shortcut(for: .hardReload)?.key == "r")
  #expect(ShortcutCatalog.shortcut(for: .hardReload)?.modifiers == [.command, .shift])
}

@MainActor @Test func siteControlCenterRendersOffscreenInLightAndDark() async throws {
  let output = URL(filePath: "/tmp/shaar-site-controls")
  try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
  let backend = FakeSiteBackend()
  let model = SiteControlsModel(target: target("https://mail.example/inbox"), backend: backend)
  await model.load()
  let pinned = ["Bitwarden", "Grammarly"].enumerated().map { index, name in
    ManagedExtension(
      id: String(repeating: index == 0 ? "a" : "b", count: 32), name: name, version: "1.0",
      description: "", enabled: true, mayDisable: true, permissions: [], hostPermissions: [])
  }
  let extensions = ExtensionManagerModel(
    profileID: model.target.profileID, extensions: pinned, pinnedIDs: pinned.map(\.id))
  let actions = SiteControlsPanelActions(
    runExtension: { _ in }, addExtensions: {}, showCertificate: {}, showDeveloperTools: {},
    close: {})
  for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
    let url = output.appending(path: "site-controls-\(name).png")
    let panel = SiteControlsPanel(
      model: model, extensions: extensions, profileName: "Work", actions: actions
    )
    .background(Color(nsColor: .windowBackgroundColor))
    let bitmap = try VisualCapture.renderOffscreen(
      panel, size: NSSize(width: 320, height: 740), appearance: appearance, to: url)
    #expect(bitmap.pixelsWide == 320)
    let text = try VisualTextRecognition.lines(in: url).joined(separator: " ")
    #expect(text.contains("Developer Tools"))
  }
  #expect(model.isAllowed(.sound))
}

@Test func certificateFingerprintsMatchChromiumsColonSeparatedForm() {
  let certificate = Data("certificate".utf8)
  let digest = SiteCertificateChain.fingerprint(of: certificate)
  #expect(digest.count == 64 && digest == digest.uppercased())
  var chromium = ""
  for (index, character) in digest.enumerated() {
    if index > 0 && index.isMultiple(of: 2) { chromium.append(":") }
    chromium.append(character)
  }
  #expect(SiteCertificateChain.fingerprint(chromium, matches: certificate))
  #expect(SiteCertificateChain.fingerprint(chromium.lowercased(), matches: certificate))
  #expect(!SiteCertificateChain.fingerprint(chromium, matches: Data("other".utf8)))
}

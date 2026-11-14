// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Security
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Test func siteControlSectionTitlesAreVoiceOverHeadings() {
  #expect(SiteSectionTitle.accessibilityTraits == .isHeader)
}

@Test func runningSiteActionStatusIsLocalized() {
  #expect(
    BrowserLocalization.string("In progress", table: "Shell", language: .english) == "In progress")
  #expect(
    BrowserLocalization.string("In progress", table: "Shell", language: .hebrew) == "בתהליך")
}

@Test @MainActor func askPermissionStateHasAnAccessibleToggleValue() {
  #expect(SitePermissionRow.accessibilityValue(for: .ask) == SettingsL10n.string("Ask"))
  #expect(SitePermissionRow.accessibilityValue(for: .block) == nil)
  #expect(SitePermissionRow.accessibilityValue(for: nil) == nil)
}

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
  var suspendNextPermissionWrite = false
  var writeCount = 0
  var finishFirstWrite: CheckedContinuation<Void, Never>?
  var suspendNextRead = false
  var finishRead: CheckedContinuation<Void, Never>?
  var suspendNextAction = false
  var finishAction: CheckedContinuation<Void, Never>?
  var suspendNextCertificateLookup = false

  func security(of target: SiteControlTarget) -> SiteSecurity { securityValue }

  func permissionValues(for target: SiteControlTarget) async throws -> [SitePermission:
    SitePermissionValue]
  {
    if failsReads { throw FakeFailure() }
    let snapshot = values
    if suspendNextRead {
      suspendNextRead = false
      await withCheckedContinuation { continuation in finishRead = continuation }
    }
    return snapshot
  }

  func setPermission(_ permission: SitePermission, allowed: Bool, for target: SiteControlTarget)
    async throws
  {
    writeCount += 1
    if suspendNextPermissionWrite {
      suspendNextPermissionWrite = false
      try await Task.sleep(for: .seconds(60))
    }
    if writeCount == 1, suspendFirstWrite {
      await withCheckedContinuation { continuation in finishFirstWrite = continuation }
    }
    if failsWrites { throw FakeFailure() }
    values[permission] = allowed ? .allow : .block
  }

  func perform(_ action: SiteAction, for target: SiteControlTarget) async throws {
    if suspendNextAction {
      suspendNextAction = false
      await withCheckedContinuation { finishAction = $0 }
    }
    if failsWrites { throw FakeFailure() }
    performed.append(action)
  }

  func certificateChain(for target: SiteControlTarget) async throws -> [SecCertificate] {
    if suspendNextCertificateLookup {
      suspendNextCertificateLookup = false
      try await Task.sleep(for: .seconds(60))
    }
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

@MainActor @Test func notificationPermissionCanBeRevokedFromSiteControls() async {
  let backend = FakeSiteBackend()
  let model = SiteControlsModel(target: target("https://mail.example"), backend: backend)
  await model.load()

  #expect(model.permissionValues[.notifications] == .ask)
  await model.setPermission(.notifications, allowed: true)
  #expect(model.permissionValues[.notifications] == .allow)
  #expect(backend.values[.notifications] == .allow)

  await model.setPermission(.notifications, allowed: false)
  #expect(model.permissionValues[.notifications] == .block)
  #expect(backend.values[.notifications] == .block)
  #expect(model.failure == nil)
}

@MainActor @Test func successfulPermissionRetryClearsStaleFailure() async {
  let backend = FakeSiteBackend()
  let model = SiteControlsModel(target: target("https://mail.example"), backend: backend)
  backend.failsReads = true
  await model.load()
  #expect(model.failure == ShellL10n.string("Could not load site permissions. Try again."))

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
  #expect(model.failure == ShellL10n.string("Could not update this permission. Try again."))
}

@MainActor @Test func latePermissionRefreshDoesNotUndoNewerToggle() async {
  let backend = FakeSiteBackend()
  let model = SiteControlsModel(target: target("https://mail.example"), backend: backend)
  await model.load()
  backend.suspendNextRead = true
  let refresh = Task { await model.load() }
  for _ in 0..<100 where backend.finishRead == nil { await Task.yield() }
  #expect(backend.finishRead != nil)

  await model.setPermission(.camera, allowed: true)
  #expect(model.permissionValues[.camera] == .allow)
  backend.finishRead?.resume()
  await refresh.value
  #expect(model.permissionValues[.camera] == .allow)
}

@MainActor @Test func cancelledPermissionLoadDoesNotPublishItsLateReply() async {
  let backend = FakeSiteBackend()
  let model = SiteControlsModel(target: target("https://mail.example"), backend: backend)
  backend.suspendNextRead = true
  let load = Task { await model.load() }
  for _ in 0..<100 where backend.finishRead == nil { await Task.yield() }
  #expect(backend.finishRead != nil)

  load.cancel()
  backend.finishRead?.resume()
  await load.value

  #expect(model.permissionValues.isEmpty)
  #expect(model.failure == nil)
}

@MainActor @Test func cancelledSiteActionDoesNotReturnSuccessAfterBackendReply() async {
  let backend = FakeSiteBackend()
  let model = SiteControlsModel(target: target("https://mail.example"), backend: backend)
  backend.suspendNextAction = true
  let action = Task { await model.perform(.reload) }
  for _ in 0..<100 where backend.finishAction == nil { await Task.yield() }
  #expect(backend.finishAction != nil)

  action.cancel()
  backend.finishAction?.resume()

  let succeeded = await action.value
  #expect(!succeeded)
  #expect(model.failure == nil)
  #expect(model.runningAction == nil)
}

@MainActor @Test func cancelledPermissionWriteRollsBackWithoutShowingFailure() async {
  let backend = FakeSiteBackend()
  let model = SiteControlsModel(target: target("https://mail.example"), backend: backend)
  await model.load()
  backend.suspendNextPermissionWrite = true
  let write = Task { await model.setPermission(.camera, allowed: true) }
  for _ in 0..<100 where !model.savingPermissions.contains(.camera) { await Task.yield() }
  #expect(model.savingPermissions.contains(.camera))

  write.cancel()
  await write.value

  #expect(model.permissionValues[.camera] == .block)
  #expect(model.failure == nil)
  #expect(model.savingPermissions.isEmpty)
}

@MainActor @Test func olderPermissionReadCannotReplaceNewerRefresh() async {
  let backend = FakeSiteBackend()
  let model = SiteControlsModel(target: target("https://mail.example"), backend: backend)
  backend.suspendNextRead = true
  let older = Task { await model.load() }
  for _ in 0..<100 where backend.finishRead == nil { await Task.yield() }
  #expect(backend.finishRead != nil)

  backend.values[.camera] = .allow
  await model.load()
  #expect(model.permissionValues[.camera] == .allow)
  backend.finishRead?.resume()
  await older.value
  #expect(model.permissionValues[.camera] == .allow)
}

@MainActor @Test func refreshDuringPermissionWriteKeepsPendingChoice() async {
  let backend = FakeSiteBackend()
  backend.suspendFirstWrite = true
  let model = SiteControlsModel(target: target("https://mail.example"), backend: backend)
  await model.load()
  let write = Task { await model.setPermission(.camera, allowed: true) }
  for _ in 0..<100 where backend.finishFirstWrite == nil { await Task.yield() }
  #expect(backend.finishFirstWrite != nil)

  await model.load()
  #expect(model.permissionValues[.camera] == .allow)
  backend.finishFirstWrite?.resume()
  await write.value
  #expect(model.permissionValues[.camera] == .allow)
  #expect(backend.values[.camera] == .allow)
}

@MainActor @Test func cancelledPermissionWriteDoesNotPublishItsLateFailure() async {
  let backend = FakeSiteBackend()
  let model = SiteControlsModel(target: target("https://mail.example"), backend: backend)
  await model.load()
  backend.suspendFirstWrite = true
  backend.failsWrites = true
  let write = Task { await model.setPermission(.camera, allowed: true) }
  for _ in 0..<100 where backend.finishFirstWrite == nil { await Task.yield() }
  #expect(backend.finishFirstWrite != nil)
  #expect(model.permissionValues[.camera] == .allow)

  write.cancel()
  backend.finishFirstWrite?.resume()
  await write.value

  #expect(model.permissionValues[.camera] == .allow)
  #expect(model.failure == nil)
  #expect(model.savingPermissions.isEmpty)
}

@MainActor @Test func cancelledSiteActionDoesNotPublishItsLateFailure() async {
  let backend = FakeSiteBackend()
  backend.suspendNextAction = true
  backend.failsWrites = true
  let model = SiteControlsModel(target: target("https://mail.example"), backend: backend)
  let action = Task { await model.perform(.reload) }
  for _ in 0..<100 where backend.finishAction == nil { await Task.yield() }
  #expect(backend.finishAction != nil)

  action.cancel()
  backend.finishAction?.resume()
  let actionSucceeded = await action.value
  #expect(!actionSucceeded)

  #expect(model.failure == nil)
  #expect(model.runningAction == nil)
}
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
  #expect(
    model.failure
      == ShellL10n.format(
        "Could not complete the %@ action. Try again.",
        arguments: [.string(SiteAction.clearCookiesAndReload.title)]) && model.runningAction == nil)
}

@MainActor @Test func certificateFailureUsesLocalizedRecoveryCopy() async {
  let backend = FakeSiteBackend()
  let model = SiteControlsModel(target: target("https://news.example"), backend: backend)
  #expect(await model.certificateChain() == nil)
  #expect(model.failure == ShellL10n.string("Could not load this site’s certificate. Try again."))
}

@MainActor @Test func cancelledCertificateLookupDoesNotShowFailure() async {
  let backend = FakeSiteBackend()
  backend.suspendNextCertificateLookup = true
  let model = SiteControlsModel(target: target("https://news.example"), backend: backend)
  let lookup = Task { await model.certificateChain() }
  await Task.yield()
  lookup.cancel()

  #expect(await lookup.value == nil)
  #expect(model.failure == nil)
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

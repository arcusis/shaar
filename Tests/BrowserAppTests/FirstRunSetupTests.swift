// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Test func firstRunMarkerResumesUntilSetupCompletes() throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }

  let marker = try #require(try FirstRunState.pendingMarker(in: directory))
  #expect(FileManager.default.fileExists(atPath: marker.path))
  try Data("saved".utf8).write(to: directory.appending(path: "workspace.json"))
  #expect(try FirstRunState.pendingMarker(in: directory) == marker)

  try FirstRunState.complete(marker)
  #expect(try FirstRunState.pendingMarker(in: directory) == nil)
}

@Test func existingWorkspaceDoesNotStartFirstRun() throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try Data("saved".utf8).write(to: directory.appending(path: "workspace.json"))
  #expect(try FirstRunState.pendingMarker(in: directory) == nil)
}

@Test func legacySessionDoesNotStartFirstRun() throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try Data("saved".utf8).write(to: directory.appending(path: "session.json"))
  #expect(try FirstRunState.pendingMarker(in: directory) == nil)
}

@Test func firstRunRecognizesTemporaryLaunchLocations() {
  let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)
  #expect(
    FirstRunLocation(application: URL(filePath: "/Volumes/Shaar/Shaar.app"), home: home)
      == .diskImage)
  #expect(
    FirstRunLocation(
      application: URL(filePath: "/private/var/folders/abc/AppTranslocation/xyz/d/Shaar.app"),
      home: home) == .diskImage)
  #expect(
    FirstRunLocation(
      application: URL(filePath: "/Users/example/Downloads/Shaar.app"), home: home)
      == .downloads)
  #expect(
    FirstRunLocation(application: URL(filePath: "/Applications/Shaar.app"), home: home)
      == .installed)
}

@Test func firstRunProductNameIsLocalizedInHebrew() {
  #expect(FirstRunBrand.name(language: .hebrew) == "שער")
  #expect(FirstRunBrand.name(language: .english) == ProductIdentity.name)
}

// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@MainActor
@Suite("Download probe destination containment")
struct DownloadProbeTests {
  @Test func downloadDirectoryMustResolveInsideTheProbeRoot() throws {
    let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let root = base.appending(path: "probe")
    let outside = base.appending(path: "outside")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let downloads = root.appending(path: "Downloads", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: false)
    #expect(DownloadProbe.isProbeDownloadDirectory(downloads, root: root))

    try FileManager.default.removeItem(at: downloads)
    try FileManager.default.createSymbolicLink(at: downloads, withDestinationURL: outside)
    #expect(!DownloadProbe.isProbeDownloadDirectory(downloads, root: root))
  }
}

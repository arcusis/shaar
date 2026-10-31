// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A single writer owns this file. The legacy session is read only when no workspace exists.
public struct WorkspaceFile: Sendable {
  public let url: URL
  public let legacySessionURL: URL

  public init(url: URL, legacySessionURL: URL) {
    self.url = url
    self.legacySessionURL = legacySessionURL
  }

  public func load() throws -> BrowserWorkspace? {
    if FileManager.default.fileExists(atPath: url.path) {
      let workspace = try JSONDecoder().decode(BrowserWorkspace.self, from: Data(contentsOf: url))
      try workspace.validate()
      return workspace
    }
    guard let legacy = try SessionFile(url: legacySessionURL).load() else { return nil }
    return try BrowserWorkspace(session: legacy)
  }

  public func save(_ workspace: BrowserWorkspace) throws {
    try workspace.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(workspace)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

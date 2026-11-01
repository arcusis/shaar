// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A single writer owns this file. The legacy session is read only when no workspace exists.
public struct WorkspaceFile: Sendable {
  public let url: URL
  public let legacySessionURL: URL
  private let snapshot: SnapshotFile<BrowserWorkspace>

  public init(url: URL, legacySessionURL: URL) {
    self.url = url
    self.legacySessionURL = legacySessionURL
    snapshot = SnapshotFile(url: url)
  }

  public func load() throws -> BrowserWorkspace? {
    if let workspace = try snapshot.load() { return workspace }
    guard let legacy = try SessionFile(url: legacySessionURL).load() else { return nil }
    return try BrowserWorkspace(session: legacy)
  }

  public func save(_ workspace: BrowserWorkspace) throws { try snapshot.save(workspace) }
}

// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public struct SessionFile: Sendable {
  public let url: URL
  private let snapshot: SnapshotFile<BrowserSession>

  public init(url: URL) {
    self.url = url
    snapshot = SnapshotFile(url: url)
  }

  public func load() throws -> BrowserSession? { try snapshot.load() }

  /// Reads only the primary file, without falling back or moving anything. For verification.
  public func loadPrimary() throws -> BrowserSession? { try snapshot.loadPrimary() }

  public func save(_ session: BrowserSession) throws { try snapshot.save(session) }
}

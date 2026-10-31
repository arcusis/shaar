// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public enum DownloadState: String, Sendable {
  case downloading, finished, cancelled, failed
}

public enum DownloadAction: String, Sendable {
  case pause, resume, cancel, remove
}

public struct BrowserDownload: Identifiable, Equatable, Sendable {
  public let id: String
  public let profileID: UUID
  public let filename: String
  public let fileURL: URL?
  public let source: String
  public let state: DownloadState
  public let paused: Bool
  public let dangerous: Bool
  public let receivedBytes: Int64
  public let totalBytes: Int64?
  public let startTime: Double

  public init?(
    id: String, profileID: UUID, filename: String, path: String, sourceURL: String,
    state: DownloadState, paused: Bool, dangerous: Bool, offTheRecord: Bool,
    received: Double, total: Double, startTime: Double
  ) {
    guard UUID(uuidString: id) != nil, id.utf8.count == 36, !offTheRecord,
      filename.utf8.count <= 4096, !filename.contains("\0"), path.utf8.count <= 16384,
      !path.contains("\0"), path.isEmpty || (path as NSString).isAbsolutePath,
      received.isFinite, received >= 0, received < Double(Int64.max),
      total.isFinite, total == -1 || (total >= 0 && total < Double(Int64.max)),
      startTime.isFinite, startTime >= 0
    else { return nil }
    self.id = id
    self.profileID = profileID
    self.filename = filename.isEmpty ? "Download" : filename
    self.fileURL = path.isEmpty ? nil : URL(filePath: path)
    self.source = Self.sourceDescription(sourceURL)
    self.state = state
    self.paused = paused
    self.dangerous = dangerous
    self.receivedBytes = Int64(received)
    self.totalBytes = total < 0 ? nil : Int64(total)
    self.startTime = startTime
  }

  public var progress: Double? {
    guard let totalBytes, totalBytes > 0 else { return nil }
    return min(Double(receivedBytes) / Double(totalBytes), 1)
  }

  public var canOpen: Bool { state == .finished && !dangerous && fileURL != nil }

  public var actions: [DownloadAction] {
    if dangerous { return state == .downloading ? [.cancel] : [.remove] }
    switch state {
    case .downloading: return paused ? [.resume, .cancel] : [.pause, .cancel]
    case .failed: return [.resume, .remove]
    case .finished, .cancelled: return [.remove]
    }
  }

  private static func sourceDescription(_ address: String) -> String {
    if address.hasPrefix("data:") { return "Generated file" }
    let value = address.hasPrefix("blob:") ? String(address.dropFirst(5)) : address
    guard value.utf8.count <= 8192, let url = URL(string: value) else { return "Download" }
    if ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host() {
      return host
    }
    return url.scheme == "chrome-extension" ? "Extension" : "Download"
  }
}

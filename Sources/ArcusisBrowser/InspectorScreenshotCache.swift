// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

struct InspectorScreenshotCache {
  let directory: URL
  init(directory: URL = InspectorScreenshotCache.defaultDirectory) {
    self.directory = directory
  }

  static var defaultDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser.appending(
      path: "Library/Caches/\(ProductIdentity.cacheFolderName)/Inspector",
      directoryHint: .isDirectory)
  }

  func save(_ png: Data, tag: String, now: Date = .now) throws -> URL {
    let manager = FileManager.default
    try manager.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let directoryValues = try directory.resourceValues(forKeys: [
      .isDirectoryKey, .isSymbolicLinkKey,
    ])
    guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else {
      throw CocoaError(.fileWriteNoPermission)
    }
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
    for file in try manager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
      ])
    where file.lastPathComponent.range(
      of: #"^[0-9]+-[a-z0-9-]+\.png$"#, options: .regularExpression) != nil
    {
      let values = try file.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
      ])
      if values.isRegularFile == true, values.isSymbolicLink != true,
        let date = values.contentModificationDate, date < cutoff
      {
        try manager.removeItem(at: file)
      }
    }
    let safeTag = String(
      tag.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(32)
    )
    let name =
      "\(Int64(now.timeIntervalSince1970 * 1_000_000))-\(safeTag.isEmpty ? "element" : safeTag).png"
    let file = directory.appending(path: name)
    try png.write(to: file, options: .atomic)
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    return file
  }
}

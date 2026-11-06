// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation

enum IncomingFileOpenPolicy {
  static let maximumFiles = 64

  static func fileURLs(from descriptor: NSAppleEventDescriptor?) -> [URL] {
    guard let descriptor else { return [] }
    let count = min(descriptor.numberOfItems, maximumFiles)
    guard count > 0 else { return [] }
    return (1...count).compactMap { descriptor.atIndex($0)?.fileURLValue }
      .compactMap(readableFileURL)
  }

  static func readableFileURL(_ url: URL) -> URL? {
    guard url.isFileURL else { return nil }
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey]),
      values.isRegularFile == true, values.isReadable == true,
      FileManager.default.isReadableFile(atPath: resolved.path)
    else { return nil }
    return resolved
  }
}

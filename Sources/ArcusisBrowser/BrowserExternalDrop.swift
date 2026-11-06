// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import UniformTypeIdentifiers

enum BrowserExternalDrop {
  static let typeIdentifiers = [UTType.url.identifier, UTType.fileURL.identifier]

  static func canReceive(_ providers: [NSItemProvider]) -> Bool {
    providers.contains { provider in
      typeIdentifiers.contains { provider.hasItemConformingToTypeIdentifier($0) }
    }
  }

  @MainActor
  static func receive(
    _ providers: [NSItemProvider], open: @escaping @MainActor (URL) -> Void
  ) -> Bool {
    guard let provider = providers.first(where: { canReceive([$0]) }) else { return false }
    let type =
      provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
      ? UTType.fileURL.identifier
      : UTType.url.identifier

    provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
      guard let url = Self.openableURL(from: item) else { return }
      Task { @MainActor in open(url) }
    }
    return true
  }

  static func openableURL(from item: NSSecureCoding?) -> URL? {
    guard let url = url(from: item) else { return nil }
    if url.isFileURL { return readableFileURL(url) }
    return IncomingURLPolicy.url(from: url.absoluteString)
  }

  private static func readableFileURL(_ url: URL) -> URL? {
    let fileURL = url.resolvingSymlinksInPath().standardizedFileURL
    guard FileManager.default.isReadableFile(atPath: fileURL.path),
      let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
      values.isRegularFile == true
    else { return nil }
    return fileURL
  }

  private static func url(from item: NSSecureCoding?) -> URL? {
    if let url = item as? URL { return url }
    if let string = item as? String { return URL(string: string) }
    if let data = item as? Data, let string = String(data: data, encoding: .utf8) {
      return URL(string: string)
    }
    return nil
  }
}

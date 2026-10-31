// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Observation

/// Last known site icons of Favorites and pinned tabs, stored per profile so the sidebar can
/// show them at launch before any page loads.
@MainActor @Observable
final class FaviconCache {
  /// Files above this size were not written by the cache and are skipped at launch.
  static let maximumIconBytes = 64 * 1024
  static let maximumIconsPerProfile = 512
  /// Four times the 16-point favicon size keeps 22-point Favorite tiles sharp on Retina displays.
  static let pixelSide = 64
  static let pointSide: CGFloat = 16

  private struct Entry {
    let image: NSImage
    let data: Data
  }

  @ObservationIgnored private let directory: URL
  private var entries: [UUID: [UUID: Entry]]

  init(directory: URL) {
    self.directory = directory
    entries = Self.load(from: directory)
  }

  func icon(for itemID: UUID, profileID: UUID) -> NSImage? {
    entries[profileID]?[itemID]?.image
  }

  func store(_ image: NSImage, for itemID: UUID, profileID: UUID) {
    guard let data = Self.pngData(for: image) else { return }
    let profileEntries = entries[profileID, default: [:]]
    guard profileEntries[itemID]?.data != data else { return }
    guard profileEntries[itemID] != nil || profileEntries.count < Self.maximumIconsPerProfile,
      let entry = Self.entry(decoding: data)
    else { return }
    entries[profileID, default: [:]][itemID] = entry
    write(data, for: itemID, profileID: profileID)
  }

  func remove(_ itemID: UUID, profileID: UUID) {
    guard entries[profileID]?.removeValue(forKey: itemID) != nil else { return }
    if entries[profileID]?.isEmpty == true {
      entries[profileID] = nil
      try? FileManager.default.removeItem(at: profileDirectory(profileID))
    } else {
      try? FileManager.default.removeItem(at: fileURL(for: itemID, profileID: profileID))
    }
  }

  /// Drops icons whose Favorite or pinned tab no longer exists, including deleted profiles.
  func retain(_ itemIDs: [UUID: Set<UUID>]) {
    for (profileID, profileEntries) in entries {
      let kept = itemIDs[profileID] ?? []
      for itemID in profileEntries.keys where !kept.contains(itemID) {
        remove(itemID, profileID: profileID)
      }
    }
  }

  private func write(_ data: Data, for itemID: UUID, profileID: UUID) {
    // A failed write only means the placeholder shows until the page loads after a restart.
    try? FileManager.default.createDirectory(
      at: profileDirectory(profileID), withIntermediateDirectories: true)
    try? data.write(to: fileURL(for: itemID, profileID: profileID), options: .atomic)
  }

  private func profileDirectory(_ profileID: UUID) -> URL {
    directory.appending(path: profileID.uuidString, directoryHint: .isDirectory)
  }

  private func fileURL(for itemID: UUID, profileID: UUID) -> URL {
    profileDirectory(profileID).appending(path: "\(itemID.uuidString).png")
  }

  private static func load(from directory: URL) -> [UUID: [UUID: Entry]] {
    var entries: [UUID: [UUID: Entry]] = [:]
    for profileURL in contents(of: directory) {
      guard let profileID = UUID(uuidString: profileURL.lastPathComponent) else { continue }
      for fileURL in contents(of: profileURL).prefix(maximumIconsPerProfile) {
        guard let itemID = itemID(of: fileURL), let entry = loadEntry(at: fileURL) else {
          continue
        }
        entries[profileID, default: [:]][itemID] = entry
      }
    }
    return entries
  }

  private static func contents(of directory: URL) -> [URL] {
    let urls = try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)
    return urls ?? []
  }

  private static func itemID(of fileURL: URL) -> UUID? {
    guard fileURL.pathExtension == "png" else { return nil }
    return UUID(uuidString: fileURL.deletingPathExtension().lastPathComponent)
  }

  private static func loadEntry(at fileURL: URL) -> Entry? {
    guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size <= maximumIconBytes,
      let data = try? Data(contentsOf: fileURL)
    else { return nil }
    return entry(decoding: data)
  }

  private static func entry(decoding data: Data) -> Entry? {
    guard let image = NSImage(data: data) else { return nil }
    image.size = NSSize(width: pointSide, height: pointSide)
    return Entry(image: image, data: data)
  }

  /// Redraws into a fixed-size sRGB bitmap so stored files stay small and independent of the
  /// display that reported the icon.
  private static func pngData(for image: NSImage) -> Data? {
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelSide, pixelsHigh: pixelSide, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
        bytesPerRow: 0, bitsPerPixel: 0)?.retagging(with: .sRGB),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: pixelSide, height: pixelSide))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
  }
}

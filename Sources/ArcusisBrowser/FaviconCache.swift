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
    let host: String?
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

  func host(for itemID: UUID, profileID: UUID) -> String? {
    entries[profileID]?[itemID]?.host
  }

  func store(_ image: NSImage, for itemID: UUID, profileID: UUID, host: String? = nil) {
    let site = Self.siteHost(host)
    if let existing = entries[profileID]?[itemID], Self.sameImage(existing.image, image) {
      recordHost(site, replacing: existing.host, for: itemID, profileID: profileID)
      return
    }
    guard let data = Self.pngData(for: image) else { return }
    let profileEntries = entries[profileID, default: [:]]
    let keptHost = site ?? profileEntries[itemID]?.host
    guard profileEntries[itemID]?.data != data else {
      recordHost(site, replacing: profileEntries[itemID]?.host, for: itemID, profileID: profileID)
      return
    }
    guard profileEntries[itemID] != nil || profileEntries.count < Self.maximumIconsPerProfile,
      let entry = Self.entry(decoding: data, host: keptHost)
    else { return }
    entries[profileID, default: [:]][itemID] = entry
    write(data, for: itemID, profileID: profileID)
    if let keptHost { writeHost(keptHost, for: itemID, profileID: profileID) }
  }

  func remove(_ itemID: UUID, profileID: UUID) {
    guard entries[profileID]?.removeValue(forKey: itemID) != nil else { return }
    if entries[profileID]?.isEmpty == true {
      entries[profileID] = nil
      if Self.isSafeDirectory(profileDirectory(profileID)) {
        try? FileManager.default.removeItem(at: profileDirectory(profileID))
      }
    } else if Self.isSafeDirectory(profileDirectory(profileID)) {
      try? FileManager.default.removeItem(at: fileURL(for: itemID, profileID: profileID))
      try? FileManager.default.removeItem(at: hostURL(for: itemID, profileID: profileID))
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
    guard Self.isSafeDirectory(profileDirectory(profileID)) else { return }
    try? data.write(to: fileURL(for: itemID, profileID: profileID), options: .atomic)
  }

  private func profileDirectory(_ profileID: UUID) -> URL {
    directory.appending(path: profileID.uuidString, directoryHint: .isDirectory)
  }

  private func fileURL(for itemID: UUID, profileID: UUID) -> URL {
    profileDirectory(profileID).appending(path: "\(itemID.uuidString).png")
  }

  private func hostURL(for itemID: UUID, profileID: UUID) -> URL {
    profileDirectory(profileID).appending(path: "\(itemID.uuidString).host")
  }

  private func recordHost(
    _ site: String?, replacing previous: String?, for itemID: UUID, profileID: UUID
  ) {
    guard let site, site != previous else { return }
    entries[profileID]?[itemID] = entries[profileID]?[itemID].map {
      Entry(image: $0.image, data: $0.data, host: site)
    }
    writeHost(site, for: itemID, profileID: profileID)
  }

  private func writeHost(_ site: String, for itemID: UUID, profileID: UUID) {
    try? FileManager.default.createDirectory(
      at: profileDirectory(profileID), withIntermediateDirectories: true)
    guard Self.isSafeDirectory(profileDirectory(profileID)) else { return }
    try? Data(site.utf8).write(to: hostURL(for: itemID, profileID: profileID), options: .atomic)
  }

  private static func isSafeDirectory(_ url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    else { return false }
    return values.isDirectory == true && values.isSymbolicLink != true
  }

  private static func load(from directory: URL) -> [UUID: [UUID: Entry]] {
    var entries: [UUID: [UUID: Entry]] = [:]
    for profileURL in contents(of: directory) {
      guard let profileID = UUID(uuidString: profileURL.lastPathComponent),
        isSafeDirectory(profileURL)
      else { continue }
      // A PNG saved before the host file existed has no site to compare. Leave it
      // on disk and skip it here so a later nil tick cannot keep the stale icon.
      // The next page load writes the icon again. Host-less files do not use a slot.
      let icons = contents(of: profileURL).filter {
        $0.pathExtension == "png" && loadHost(beside: $0) != nil
      }
      for fileURL in icons.prefix(maximumIconsPerProfile) {
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
    guard isSafeRegularFile(fileURL),
      let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size <= maximumIconBytes,
      let data = try? Data(contentsOf: fileURL)
    else { return nil }
    return entry(decoding: data, host: loadHost(beside: fileURL))
  }

  private static func isSafeRegularFile(_ url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    else { return false }
    return values.isRegularFile == true && values.isSymbolicLink != true
  }

  private static func loadHost(beside fileURL: URL) -> String? {
    let hostURL = fileURL.deletingPathExtension().appendingPathExtension("host")
    guard isSafeRegularFile(hostURL) else { return nil }
    guard let text = try? String(contentsOf: hostURL, encoding: .utf8) else { return nil }
    return siteHost(text)
  }

  private static func siteHost(_ host: String?) -> String? {
    guard let host = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      !host.isEmpty, host.count <= 253, !host.contains("/")
    else { return nil }
    return host
  }

  private static func entry(decoding data: Data, host: String?) -> Entry? {
    guard let image = NSImage(data: data) else { return nil }
    image.size = NSSize(width: pointSide, height: pointSide)
    return Entry(image: image, data: data, host: host)
  }

  /// True when both images already have the same bitmap, so the cache can skip a redraw.
  static func sameImage(_ lhs: NSImage, _ rhs: NSImage) -> Bool {
    guard let left = lhs.tiffRepresentation, let right = rhs.tiffRepresentation else {
      return false
    }
    return left == right
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

// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation

/// An installed extension as `chrome.management` reports it for one profile.
struct ManagedExtension: Identifiable, Equatable, Decodable {
  let id: String
  let name: String
  let version: String
  let description: String
  let enabled: Bool
  let mayDisable: Bool
  let permissions: [String]
  let hostPermissions: [String]
  var siteAccess: String? = nil
  var incognitoEnabled: Bool? = nil

  func help(actionTitle: String?) -> String {
    guard let title = actionTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
      !title.isEmpty, title != name
    else { return name }
    return "\(name): \(title)"
  }
}

enum ExtensionManagementOperation: Equatable {
  case list
  case setEnabled(id: String, enabled: Bool)
  case uninstall(id: String)
  case details(id: String)

  var extensionID: String? {
    switch self {
    case .list: nil
    case .setEnabled(let id, _), .uninstall(let id), .details(let id): id
    }
  }

  var bridgeOperation: ARCExtensionManagementOperation {
    switch self {
    case .list: .list
    case .setEnabled: .setEnabled
    case .uninstall: .uninstall
    case .details: .details
    }
  }

  var enabled: Bool {
    guard case .setEnabled(_, let enabled) = self else { return false }
    return enabled
  }

  static func isValidProfileID(_ value: String) -> Bool {
    guard let id = UUID(uuidString: value) else { return false }
    return id.uuidString.caseInsensitiveCompare(value) == .orderedSame
  }
}

enum ExtensionSiteAccess: String, CaseIterable, Identifiable {
  case onClick
  case onSite
  case onAllSites

  var id: String { rawValue }

  var title: String {
    switch self {
    case .onClick: SettingsL10n.string("On click")
    case .onSite: SettingsL10n.string("On this site")
    case .onAllSites: SettingsL10n.string("On all sites")
    }
  }

  static func recognized(_ raw: String?) -> ExtensionSiteAccess? {
    guard let raw else { return nil }
    return ExtensionSiteAccess(rawValue: raw)
  }
}

enum ExtensionInstallNotice {
  static var needsNewerEngine: String {
    SettingsL10n.string("This feature needs a newer Shaar engine.")
  }

  static var siteAccessRefused: String {
    SettingsL10n.string("This Shaar engine cannot change extension site access yet.")
  }

  static var installFailed: String {
    SettingsL10n.string("The extension could not be installed.")
  }

  static var developerModeFailed: String {
    SettingsL10n.string("Developer mode could not be changed.")
  }

  static var privateAccessRefused: String {
    SettingsL10n.string("This Shaar engine cannot change private-window access yet.")
  }
}

/// The page origin Shaar sends with a site-access change. Default ports stay omitted,
/// and an IPv6 host keeps its brackets.
enum ExtensionPageOrigin {
  static func string(from url: URL) -> String? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = components.host?.lowercased(), !host.isEmpty,
      components.port.map({ (0...65535).contains($0) }) ?? true
    else { return nil }
    let bareHost =
      host.hasPrefix("[") && host.hasSuffix("]")
      ? String(host.dropFirst().dropLast()) : host
    let formattedHost = bareHost.contains(":") ? "[\(bareHost)]" : bareHost
    if let port = components.port, !isDefault(port, scheme: scheme) {
      return "\(scheme)://\(formattedHost):\(port)"
    }
    return "\(scheme)://\(formattedHost)"
  }

  private static func isDefault(_ port: Int, scheme: String) -> Bool {
    (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
  }

  static func accepts(_ origin: String) -> Bool {
    guard let url = URL(string: origin) else { return false }
    return string(from: url) == origin
  }
}

/// A directory the user chose for an unpacked Manifest V3 extension.
enum ExtensionUnpackedFolder {
  static func directory(_ url: URL) -> String? {
    guard url.isFileURL else { return nil }
    let folder = url.standardizedFileURL
    guard folder.path.hasPrefix("/"), !folder.path.contains("..") else { return nil }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return nil }
    let manifest = folder.appending(path: "manifest.json")
    guard
      let sizeValues = try? manifest.resourceValues(forKeys: [.fileSizeKey]),
      let manifestSize = sizeValues.fileSize, manifestSize <= 1_048_576,
      let values = try? manifest.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
      values.isRegularFile == true, values.isSymbolicLink != true,
      let data = try? Data(contentsOf: manifest), data.count <= 1_048_576,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["manifest_version"] as? Int == 3,
      let name = object["name"] as? String,
      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return folder.path
  }
}

enum ExtensionManageReply: Equatable {
  case prompted
  case updated
  case unsupported
  case failed

  init(json: String?, code: Int, action: String? = nil) {
    if code == 15 {
      self = .unsupported
      return
    }
    if code == 1 {
      self =
        ["setDeveloperMode", "loadUnpacked"].contains(action ?? "")
        ? .unsupported : .failed
      return
    }
    guard code == 0, let data = json?.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["schemaVersion"] as? Int == 1
    else {
      self = .failed
      return
    }
    if object["prompted"] as? Bool == true {
      self = .prompted
      return
    }
    self = .updated
  }
}

enum ExtensionConsentPermissions {
  static let unknownAccess = PanelsL10n.string("Unknown access")

  static func displayValues(
    permissions: [String], hostPermissions: [String]?, complete: Bool
  ) -> [String] {
    var values = permissions
    if let hostPermissions {
      values += hostPermissions.map { PanelsL10n.format("Site access: %@", .string($0)) }
    }
    if !complete || hostPermissions == nil {
      values.append(unknownAccess)
    }
    return values
  }
}

enum ExtensionManagementResult {
  case value(Data)
  case failure(String)

  init?(json: String?) {
    guard let data = json?.data(using: .utf8) else { return nil }
    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let error = object["error"] as? String
    {
      self = .failure(error)
    } else {
      self = .value(data)
    }
  }
}

/// Reads an extension's icon from its installed manifest; Chromium keeps one folder per version.
enum ExtensionIconLoader {
  static func icon(for extensionID: String, version: String, in extensionsDirectory: URL)
    -> NSImage?
  {
    guard BrowserExtension.isValidID(extensionID) else { return nil }
    let root = extensionsDirectory.appending(path: extensionID, directoryHint: .isDirectory)
    guard
      let folder = try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil
      ).first(where: { $0.lastPathComponent.hasPrefix("\(version)_") })
    else { return nil }
    let manifestURL = folder.appending(path: "manifest.json")
    guard
      let manifestValues = try? manifestURL.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
      manifestValues.isRegularFile == true, manifestValues.isSymbolicLink != true,
      let data = try? Data(contentsOf: manifestURL),
      let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let relative = largestIcon(in: manifest)
    else { return nil }
    let file = folder.appending(path: relative).standardizedFileURL
    // Manifest paths are untrusted; never read outside the extension's own folder.
    guard file.path.hasPrefix(folder.standardizedFileURL.path + "/") else { return nil }
    return NSImage(contentsOf: file)
  }

  private static func largestIcon(in manifest: [String: Any]) -> String? {
    let action = (manifest["action"] ?? manifest["browser_action"]) as? [String: Any]
    for candidate in [manifest["icons"], action?["default_icon"]] {
      if let path = candidate as? String { return path }
      if let sizes = candidate as? [String: String],
        let largest = sizes.max(by: { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) })
      {
        return largest.value
      }
    }
    return nil
  }
}

enum ExtensionManageDelivery {
  static func deliver(
    _ reply: ExtensionManageReply,
    to completion: @escaping @MainActor @Sendable (ExtensionManageReply) -> Void
  ) {
    if Thread.isMainThread {
      MainActor.assumeIsolated { completion(reply) }
      return
    }
    DispatchQueue.main.async {
      MainActor.assumeIsolated { completion(reply) }
    }
  }

  static func deliver(
    _ reply: String?, to completion: @escaping @MainActor @Sendable (String?) -> Void
  ) {
    if Thread.isMainThread {
      MainActor.assumeIsolated { completion(reply) }
      return
    }
    DispatchQueue.main.async {
      MainActor.assumeIsolated { completion(reply) }
    }
  }
}

extension ARCChromiumRuntime {
  /// Submits one extension-manage payload and interprets legacy refusal codes by action.
  func submitExtensionManage(
    profileID: UUID, tabID: UUID?, payload: [String: Any],
    completion: @escaping @MainActor @Sendable (ExtensionManageReply) -> Void
  ) {
    let action = payload["action"] as? String
    submitExtensionManage(
      forProfileID: profileID.uuidString, tabID: tabID?.uuidString, payload: payload
    ) { json, code in
      let reply = ExtensionManageReply(json: json, code: code, action: action)
      ExtensionManageDelivery.deliver(reply, to: completion)
    }
  }

  /// Runs one extension-management operation; the bridge builds the script from fixed templates.
  func manageExtensions(
    _ operation: ExtensionManagementOperation, profileID: UUID,
    completion: @escaping @MainActor @Sendable (String?) -> Void
  ) {
    manageExtensions(
      forProfileID: profileID.uuidString, operation: operation.bridgeOperation,
      extensionID: operation.extensionID, enabled: operation.enabled
    ) { json in
      ExtensionManageDelivery.deliver(json, to: completion)
    }
  }
}

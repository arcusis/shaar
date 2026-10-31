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

enum ExtensionConsentPermissions {
  static let unknownAccess = "Unknown access"

  static func displayValues(
    permissions: [String], hostPermissions: [String]?, complete: Bool
  ) -> [String] {
    var values = permissions
    if let hostPermissions {
      values += hostPermissions.map { "Site access: \($0)" }
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
      ).first(where: { $0.lastPathComponent.hasPrefix("\(version)_") }),
      let data = try? Data(contentsOf: folder.appending(path: "manifest.json")),
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

extension ARCChromiumRuntime {
  /// Runs one extension-management operation; the bridge builds the script from fixed templates.
  func manageExtensions(
    _ operation: ExtensionManagementOperation, profileID: UUID,
    completion: @escaping (String?) -> Void
  ) {
    manageExtensions(
      forProfileID: profileID.uuidString, operation: operation.bridgeOperation,
      extensionID: operation.extensionID, enabled: operation.enabled, completion: completion)
  }
}

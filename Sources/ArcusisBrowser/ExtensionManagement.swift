import AppKit
import BrowserCore
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

/// Expressions run by Shaar's bundled manager extension. Only validated IDs reach them.
enum ExtensionManagementScript {
  static let list = """
    chrome.management.getAll().then(all => all.filter(e => e.type === 'extension').map(e => ({
      id: e.id, name: e.name, version: e.version, description: e.description || '',
      enabled: e.enabled, mayDisable: e.mayDisable, permissions: e.permissions || [],
      hostPermissions: e.hostPermissions || []})))
    """

  static func setEnabled(_ id: String, _ enabled: Bool) -> String? {
    guard BrowserExtension.isValidID(id) else { return nil }
    return "chrome.management.setEnabled('\(id)', \(enabled)).then(() => true)"
  }

  static func uninstall(_ id: String) -> String? {
    guard BrowserExtension.isValidID(id) else { return nil }
    return "chrome.management.uninstall('\(id)', {showConfirmDialog: false}).then(() => true)"
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

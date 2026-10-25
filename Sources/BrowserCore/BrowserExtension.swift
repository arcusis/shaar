import Foundation

public struct BrowserExtension: Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let version: String

  public init?(id: String, name: String, version: String) {
    guard Self.isValidID(id), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      name.utf8.count <= 1024, !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      version.utf8.count <= 128
    else { return nil }
    self.id = id
    self.name = name
    self.version = version
  }

  public static func isValidID(_ id: String) -> Bool {
    id.utf8.count == 32 && id.utf8.allSatisfy { (97...112).contains($0) }
  }
}

public enum ExtensionInstallKind: String, Sendable {
  case install, permissions
  case reenable = "re-enable"
  case repair

  public var actionTitle: String {
    switch self {
    case .install: "Add extension"
    case .permissions: "Allow permissions"
    case .reenable: "Enable extension"
    case .repair: "Repair extension"
    }
  }
}

/// An engine-issued request is bound to the exact profile, tab, and page that requested it.
public struct ExtensionInstallRequest: Identifiable, Equatable, Sendable {
  public let id: String
  public let profileID: UUID
  public let tabID: UUID
  public let sourceURL: URL
  public let browserExtension: BrowserExtension
  public let kind: ExtensionInstallKind
  public let permissions: [String]

  public init?(
    id: String, profileID: UUID, tabID: UUID, sourceURL: URL,
    browserExtension: BrowserExtension, kind: ExtensionInstallKind, permissions: [String]
  ) {
    guard !id.isEmpty, id.utf8.count <= 128, !browserExtension.name.isEmpty,
      browserExtension.name.utf8.count <= 1024, browserExtension.version.utf8.count <= 128,
      permissions.count <= 128, permissions.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8192 }),
      permissions.reduce(0, { $0 + $1.utf8.count }) <= 65536,
      NavigationInput.isWebURL(sourceURL)
    else { return nil }
    self.id = id
    self.profileID = profileID
    self.tabID = tabID
    self.sourceURL = sourceURL
    self.browserExtension = browserExtension
    self.kind = kind
    self.permissions = permissions
  }

  public func matches(_ session: BrowserSession) -> Bool {
    session.selectedSpace.profileID == profileID
      && session.selectedPage?.tab.id == tabID
      && session.selectedPage?.tab.url == sourceURL
      && session.profileID(forTabID: tabID) == profileID
  }
}

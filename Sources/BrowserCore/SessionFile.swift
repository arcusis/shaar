import Foundation

public struct SessionFile: Sendable {
  public let url: URL

  public init(url: URL) { self.url = url }

  public func load() throws -> BrowserSession? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let session = try JSONDecoder().decode(BrowserSession.self, from: Data(contentsOf: url))
    try session.validate()
    return session
  }

  public func save(_ session: BrowserSession) throws {
    try session.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(session)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

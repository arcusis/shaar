import BrowserCore
import Foundation
import Testing

@Test func downloadMetadataBoundsPathsNumbersAndPrivateRecords() throws {
  func item(
    path: String = "/tmp/report.pdf",
    source: String = "https://files.example.com/report?secret=token",
    privateItem: Bool = false, received: Double = 12, total: Double = 20,
    state: DownloadState = .finished, dangerous: Bool = false
  ) -> BrowserDownload? {
    BrowserDownload(
      id: "9b948ba6-d386-4e34-acdf-b2fb92fdb34b", profileID: UUID(), filename: "report.pdf",
      path: path, sourceURL: source, state: state, paused: false,
      dangerous: dangerous, offTheRecord: privateItem, received: received, total: total,
      startTime: 1)
  }
  let safe = try #require(item())
  #expect(safe.source == "files.example.com")
  #expect(safe.canOpen)
  #expect(safe.progress == 0.6)
  #expect(item(privateItem: true) == nil)
  #expect(item(path: "relative/file") == nil)
  #expect(item(path: "/tmp/bad\0path") == nil)
  #expect(item(received: .infinity) == nil)
  #expect(item(received: -1) == nil)
  #expect(item(received: Double(Int64.max)) == nil)
  #expect(item(total: -2) == nil)
  #expect(item(total: .nan) == nil)
  #expect(item(total: -1)?.totalBytes == nil)
  #expect(item(received: 30)?.progress == 1)
  #expect(item(path: "")?.canOpen == false)
  #expect(item(state: .downloading)?.canOpen == false)
  #expect(item(source: "blob:https://docs.example.com/id")?.source == "docs.example.com")
  #expect(item(source: "data:text/plain,secret")?.source == "Generated file")
  #expect(item(dangerous: true)?.canOpen == false)
  #expect(item(state: .downloading, dangerous: true)?.actions == [.cancel])
  #expect(item(dangerous: true)?.actions == [.remove])
}

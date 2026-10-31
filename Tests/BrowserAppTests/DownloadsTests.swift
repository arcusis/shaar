import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct DownloadsTests {
  private let id = "8ce51349-a188-4bad-bd1c-011b48e48ca6"
  private func record(
    state: String = "downloading", paused: Bool = false, privateItem: Bool = false
  )
    -> [String: Any]
  {
    [
      "id": id, "filename": "file.txt", "path": "/tmp/file.txt", "url": "https://example.com/file",
      "state": state, "paused": paused, "dangerous": false, "offTheRecord": privateItem,
      "received": 20.0, "total": 100.0, "startTime": 1.0,
    ]
  }

  @Test func commandsStayBoundToTheirProfileAndCurrentAllowedState() {
    let model = DownloadsModel()
    let a = UUID()
    let b = UUID()
    model.changed(record(), profileID: a)
    model.changed(record(paused: true), profileID: b)
    var calls: [String] = []
    model.onCommand = { action, id, profile, completion in
      calls.append("\(profile):\(id):\(action)")
      completion(nil)
    }
    #expect(!model.perform(.cancel, id: id, profileID: a, selectedProfileID: b))
    #expect(!model.perform(.remove, id: id, profileID: a, selectedProfileID: a))
    #expect(!model.perform(.resume, id: id, profileID: a, selectedProfileID: a))
    #expect(calls.isEmpty)
    #expect(model.perform(.pause, id: id, profileID: a, selectedProfileID: a))
    #expect(calls == ["\(a):\(id):pause"])
    model.removed(id, profileID: a)
    #expect(model.items(in: a).isEmpty)
    #expect(model.items(in: b).count == 1)
    #expect(model.items(in: b).first?.paused == true)
  }

  @Test func restorationRejectsPrivateMalformedAndUnknownStateRecords() {
    let model = DownloadsModel()
    let profile = UUID()
    var broken = record()
    broken["dangerous"] = nil
    model.restore(
      [record(privateItem: true), broken, record(state: "unknown")], profileID: profile)
    #expect(model.items(in: profile).isEmpty)
    model.restore([record(state: "finished")], profileID: profile)
    #expect(model.items(in: profile).count == 1)
    #expect(model.fileToOpen(id: id, profileID: profile, selectedProfileID: UUID()) == nil)
    #expect(
      model.fileToOpen(id: id, profileID: profile, selectedProfileID: profile)?.path
        == "/tmp/file.txt")
    var unsafe = record(state: "finished")
    unsafe["dangerous"] = true
    model.changed(unsafe, profileID: profile)
    #expect(model.fileToOpen(id: id, profileID: profile, selectedProfileID: profile) == nil)
  }

  @Test func lateCommandErrorsDoNotLeakIntoAnotherProfile() {
    let model = DownloadsModel()
    let a = UUID()
    let b = UUID()
    model.changed(record(), profileID: a)
    var finish: (@MainActor @Sendable (String?) -> Void)?
    model.onCommand = { _, _, _, completion in finish = completion }
    #expect(model.perform(.pause, id: id, profileID: a, selectedProfileID: a))
    finish?("Could not pause")
    #expect(model.notices[a] == "Could not pause")
    #expect(model.notices[b] == nil)
  }

  @Test func downloadsPresentationCannotReplaceConsentAndClosesOnProfileChange() throws {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://example.com")!))
    store.showPageFind()
    store.showDownloads()
    #expect(store.pageFind == nil)
    if case .downloads(let profile) = store.sheet {
      #expect(profile == store.session.selectedSpace.profileID)
    } else {
      Issue.record("Expected profile-scoped downloads sheet")
    }
    store.cycleSpace(by: 1)
    #expect(store.sheet == nil)
    store.perform(.open(URL(string: "https://example.com")!))
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let request = try #require(
      WebsitePermissionRequest(
        id: "p1", profileID: store.session.selectedSpace.profileID, tabID: tab.id,
        pageURL: tab.url, requestingOrigin: URL(string: "https://example.com")!, kinds: [.camera]))
    #expect(store.requestWebsitePermission(request))
    store.showDownloads()
    #expect(store.sheet?.id == "permission-p1")
  }
}

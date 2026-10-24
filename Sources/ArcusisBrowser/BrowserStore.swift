import BrowserCore
import Foundation
import Observation

@MainActor @Observable
final class BrowserStore {
  private(set) var session: BrowserSession
  var commandIsOpen = false
  var commandQuery = ""
  var commandSelection = 0
  var sidebarIsVisible = true
  var spaceEditor: SpaceEditorRoute?
  private(set) var storageNotice: String?

  @ObservationIgnored private let sessionFile: SessionFile?
  @ObservationIgnored private var maySave = true

  init(sessionFile: SessionFile? = nil, session: BrowserSession = .fresh()) {
    self.sessionFile = sessionFile
    self.session = session
    do {
      if let saved = try sessionFile?.load() {
        self.session = saved
      } else {
        save()
      }
    } catch {
      maySave = false
      storageNotice =
        "Saved session could not be restored. The original file is preserved; changes in this window will not be saved."
    }
  }

  var results: [CommandResult] { CommandSearch.results(for: commandQuery, in: session) }
  var profileName: String {
    session.profiles.first { $0.id == session.selectedSpace.profileID }?.name ?? ""
  }

  func showCommand() {
    commandQuery = ""
    commandSelection = 0
    commandIsOpen = true
  }

  func dismissCommand() { commandIsOpen = false }

  func moveCommandSelection(by amount: Int) {
    guard !results.isEmpty else { return }
    commandSelection = min(max(commandSelection + amount, 0), results.count - 1)
  }

  func acceptCommand() {
    let results = results
    guard results.indices.contains(commandSelection) else { return }
    perform(results[commandSelection].action)
  }

  func perform(_ action: CommandAction) {
    switch action {
    case .open(let url): session.open(url)
    case .space(let id): session.selectSpace(id)
    case .tab(let space, let tab): session.selectTab(tab, in: space)
    }
    commandIsOpen = false
    save()
  }

  func cycleSpace(by offset: Int) {
    session.cycleSpace(by: offset)
    save()
  }

  func closeTab(_ id: UUID) {
    session.closeTab(id)
    save()
  }

  func togglePin(_ id: UUID) {
    session.togglePin(id)
    save()
  }

  @discardableResult
  func createSpace(name: String, sharingProfile profileID: UUID?, tint: SpaceTint) -> Bool {
    guard session.addSpace(name: name, sharingProfile: profileID, tint: tint) != nil else {
      return false
    }
    save()
    return true
  }

  @discardableResult
  func updateSpace(_ id: UUID, name: String, tint: SpaceTint) -> Bool {
    guard session.updateSpace(id, name: name, tint: tint) else { return false }
    save()
    return true
  }

  @discardableResult
  func removeSpace(_ id: UUID) -> Bool {
    guard session.removeSpace(id) else { return false }
    save()
    return true
  }

  private func save() {
    guard maySave else { return }
    do {
      try sessionFile?.save(session)
      storageNotice = nil
    } catch {
      storageNotice = "Changes could not be saved. \(error.localizedDescription)"
    }
  }

  static func persistent() -> BrowserStore {
    let support = URL.applicationSupportDirectory
      .appending(path: "Arcusis Browser", directoryHint: .isDirectory)
      .appending(path: "session.json")
    return BrowserStore(sessionFile: SessionFile(url: support))
  }

  static func preview(showCommand: Bool) -> BrowserStore {
    var session = BrowserSession.fresh()
    for address in ["https://github.com", "https://linear.app", "https://developer.apple.com"] {
      if let url = URL(string: address), let id = session.open(url) { session.togglePin(id) }
    }
    if let url = URL(string: "https://github.com/arcusis/browser") { session.open(url) }
    let store = BrowserStore(session: session)
    store.commandIsOpen = showCommand
    return store
  }
}

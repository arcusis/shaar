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
  private(set) var pageFind: PageFindState?
  var sheet: BrowserSheet?
  var spaceEditor: SpaceEditorRoute? {
    get {
      if case .space(let route) = sheet { return route }
      return nil
    }
    set {
      if sheet?.isConsent == true { return }
      if newValue != nil { dismissPageFind() }
      sheet = newValue.map(BrowserSheet.space)
    }
  }
  private var consentRequests: [BrowserSheet] = []
  var installationRequests: [ExtensionInstallRequest] {
    consentRequests.compactMap {
      if case .extensionInstall(let request) = $0 { return request }
      return nil
    }
  }
  var websiteMediaRequests: [WebsiteMediaRequest] {
    consentRequests.compactMap {
      if case .websiteMedia(let request) = $0 { return request }
      return nil
    }
  }
  private(set) var storageNotice: String?

  @ObservationIgnored private let sessionFile: SessionFile?
  @ObservationIgnored private var maySave = true
  @ObservationIgnored var engine: BrowserEngine?
  @ObservationIgnored var onSessionChanged: (() -> Void)?
  @ObservationIgnored var onCloseTab: ((UUID) -> Void)?
  @ObservationIgnored var onInstallDecision: ((String, Bool) -> Void)?
  @ObservationIgnored var onWebsiteMediaDecision: ((String, Bool) -> Void)?
  @ObservationIgnored var onFindRequest: ((PageFindState, Bool) -> Bool)?
  @ObservationIgnored var onStopFinding: ((UUID) -> Void)?
  @ObservationIgnored private var presentedConsentID: String?

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
    dismissPageFind()
    commandQuery = ""
    commandSelection = 0
    commandIsOpen = true
  }

  func dismissCommand() { commandIsOpen = false }

  func showDownloads() {
    guard sheet == nil else { return }
    dismissCommand()
    dismissPageFind()
    engine?.extensionPanel = nil
    sheet = .downloads(profileID: session.selectedSpace.profileID)
    engine?.runtime.refreshDownloads(forProfileID: session.selectedSpace.profileID.uuidString)
  }

  func showPageFind() {
    guard sheet == nil, let tab = session.selectedSpace.selectedTab else { return }
    commandIsOpen = false
    engine?.extensionPanel = nil
    if var current = pageFind, current.matches(session) {
      current.focusRequest = UUID()
      pageFind = current
    } else {
      dismissPageFind()
      pageFind = PageFindState(
        profileID: session.selectedSpace.profileID, tabID: tab.id, pageURL: tab.url)
    }
  }

  func updatePageFindQuery(_ query: String) {
    guard var current = pageFind, current.matches(session), current.query != query else { return }
    current.query = query
    current.matchCount = nil
    current.activeMatch = 0
    current.unavailable = false
    issueFind(current, forward: true)
  }

  func movePageFind(forward: Bool) {
    guard let current = pageFind, current.matches(session), current.canMove else { return }
    issueFind(current, forward: forward)
  }

  private func issueFind(_ value: PageFindState, forward: Bool) {
    var current = value
    current.requestID = UUID()
    current.searching = !current.query.isEmpty
    pageFind = current
    if current.query.isEmpty {
      onStopFinding?(current.tabID)
    } else if onFindRequest?(current, forward) == false {
      current.searching = false
      current.unavailable = true
      pageFind = current
    }
  }

  func receiveFindResult(tabID: UUID, requestID: UUID, count: Int, active: Int, final: Bool) {
    guard var current = pageFind, current.matches(session), current.tabID == tabID,
      current.requestID == requestID, !current.query.isEmpty
    else { return }
    if count >= 0 { current.matchCount = count }
    if active >= 0 { current.activeMatch = active }
    if let count = current.matchCount { current.activeMatch = min(current.activeMatch, count) }
    current.searching = !final
    pageFind = current
  }

  func dismissPageFind() {
    guard let current = pageFind else { return }
    pageFind = nil
    onStopFinding?(current.tabID)
  }

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
    if let onCloseTab {
      onCloseTab(id)
      return
    }
    nativeTabClosed(id)
  }

  func nativeTabClosed(_ id: UUID) {
    session.closeTab(id)
    save()
  }

  func nativeTabChanged(_ id: UUID, url: URL, title: String) {
    if session.updateTab(id, url: url, title: title) { save() }
  }

  func nativeTabOpened(_ tab: BrowserTab, profileID: UUID, openerID: UUID?, foreground: Bool)
    -> Bool
  {
    guard
      session.insertNativeTab(tab, profileID: profileID, openerID: openerID, foreground: foreground)
        != nil
    else { return false }
    save()
    return true
  }

  @discardableResult
  func requestInstallation(_ request: ExtensionInstallRequest) -> Bool {
    enqueueConsent(.extensionInstall(request))
  }

  func resolveInstallation(_ id: String, accepted: Bool) {
    resolveConsent("install-\(id)", accepted: accepted)
  }

  @discardableResult
  func requestWebsiteMedia(_ request: WebsiteMediaRequest) -> Bool {
    enqueueConsent(.websiteMedia(request))
  }

  func resolveWebsiteMedia(_ id: String, accepted: Bool) {
    resolveConsent("media-\(id)", accepted: accepted)
  }

  private func enqueueConsent(_ request: BrowserSheet) -> Bool {
    guard request.isConsent, request.matches(session), consentRequests.count < 10,
      !consentRequests.contains(where: { $0.id == request.id })
    else { return false }
    consentRequests.append(request)
    dismissPageFind()
    presentNextConsent()
    return true
  }

  private func resolveConsent(_ id: String, accepted: Bool) {
    guard let request = consentRequests.first(where: { $0.id == id }) else { return }
    let presented = sheet?.id == id && presentedConsentID == id
    consentRequests.removeAll { $0.id == id }
    if presentedConsentID == id { presentedConsentID = nil }
    if presented { sheet = nil }
    let allow = accepted && presented && request.matches(session)
    switch request {
    case .extensionInstall(let request): onInstallDecision?(request.id, allow)
    case .websiteMedia(let request): onWebsiteMediaDecision?(request.id, allow)
    case .space, .downloads: break
    }
  }

  func presentNextConsent() {
    guard sheet == nil, let request = consentRequests.first else { return }
    presentedConsentID = request.id
    sheet = request
  }

  func sheetDidDismiss() {
    if let id = presentedConsentID { resolveConsent(id, accepted: false) }
    presentNextConsent()
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
    if case .downloads(let profile) = sheet, profile != session.selectedSpace.profileID {
      sheet = nil
    }
    if let current = pageFind, !current.matches(session) { dismissPageFind() }
    for request in consentRequests where !request.matches(session) {
      resolveConsent(request.id, accepted: false)
    }
    defer { onSessionChanged?() }
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

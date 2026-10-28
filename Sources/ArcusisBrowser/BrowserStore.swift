import BrowserCore
import Foundation
import Observation
import os

struct ManagedSessionSaveResult {
  let session: BrowserSession
  let notice: String?
}

struct SpaceRemovalImpact {
  let tabs: Int
  let windows: Int
  var favoritePages: Int = 0
  var tabDescription: String { "\(tabs) \(tabs == 1 ? "tab" : "tabs")" }

  var message: String {
    let favoriteImpact =
      favoritePages == 0
      ? "" : " and \(favoritePages) Favorite \(favoritePages == 1 ? "page" : "pages")"
    return windows > 1
      ? "This space will be deleted from all \(windows) windows, closing \(tabDescription)\(favoriteImpact). Its profile is kept."
      : "Tabs in this space will close\(favoriteImpact). Its profile is kept."
  }
}

@MainActor @Observable
final class BrowserStore {
  private(set) var session: BrowserSession
  let dragSessionID = UUID()
  let library = BrowserLibraryModel()
  private(set) var sidebarNotice: String?
  var commandIsOpen = false
  var commandQuery = ""
  var commandEditsCurrentURL = false
  var commandSelection = 0
  var sidebarIsVisible = true
  private(set) var pageFind: PageFindState?
  private(set) var rendererFailures: [UUID: RendererFailure] = [:]
  var sheet: BrowserSheet? {
    didSet {
      if sheet != nil { closeLibraryDrawer() }
    }
  }
  private(set) var libraryDrawerSection: LibraryDrawerSection?
  private(set) var libraryDrawerProfileID: UUID?
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
  var externalAppRequests: [ExternalAppRequest] {
    consentRequests.compactMap {
      if case .externalApp(let request) = $0 { return request }
      return nil
    }
  }
  private(set) var storageNotice: String?

  @ObservationIgnored private let sessionFile: SessionFile?
  @ObservationIgnored var preferences = BrowserPreferencesStore()
  @ObservationIgnored private var managedSave: ((BrowserSession, Bool) -> ManagedSessionSaveResult)?
  @ObservationIgnored private let snapshotScheduler = SnapshotSaveScheduler()
  @ObservationIgnored private let switchLog = OSLog(subsystem: "com.arcusis.browser", category: "SpaceSwitch")
  @ObservationIgnored private var maySave = true
  @ObservationIgnored var engine: BrowserEngine?
  @ObservationIgnored var onSessionChanged: (() -> Void)?
  @ObservationIgnored var onCloseTab: ((UUID) -> Void)?
  @ObservationIgnored var onInstallDecision: ((String, Bool) -> Void)?
  @ObservationIgnored var onWebsiteMediaDecision: ((String, Bool) -> Void)?
  @ObservationIgnored var onExternalAppDecision: ((String, Bool) -> Void)?
  @ObservationIgnored var onFindRequest: ((PageFindState, Bool) -> Bool)?
  @ObservationIgnored var onStopFinding: ((UUID) -> Void)?
  @ObservationIgnored var onReloadPage: ((UUID, UUID) -> Bool)?
  @ObservationIgnored var onSpaceRemovalImpact: ((UUID) -> SpaceRemovalImpact)?
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

  init(
    managedSession: BrowserSession, notice: String?,
    save: @escaping (BrowserSession, Bool) -> ManagedSessionSaveResult
  ) {
    sessionFile = nil
    session = managedSession
    storageNotice = notice
    managedSave = save
  }

  /// Workspace projections refresh the view/engine without starting another persistence transaction.
  func applyManagedSession(_ value: BrowserSession, notice: String?) {
    guard managedSave != nil else { return }
    let changed = session != value
    session = value
    storageNotice = notice
    reconcileTransientState()
    if changed { onSessionChanged?() }
  }

  var results: [CommandResult] {
    let profile = session.selectedSpace.profileID
    return CommandSearch.results(
      for: commandQuery, in: session,
      bookmarks: library.bookmarks[profile]?.items ?? [], history: library.history[profile] ?? [],
      searchEngine: preferences.searchEngine(for: profile))
  }
  func usePreferences(_ value: BrowserPreferencesStore) {
    preferences = value
    sidebarIsVisible = value.sidebarInitiallyVisible
  }

  var profileName: String {
    session.profiles.first { $0.id == session.selectedSpace.profileID }?.name ?? ""
  }

  func showCommand() {
    closeLibraryDrawer()
    dismissPageFind()
    commandEditsCurrentURL = false
    commandQuery = ""
    commandSelection = 0
    commandIsOpen = true
  }

  func dismissCommand() { commandIsOpen = false }

  var canUseLibraryDrawer: Bool {
    sheet == nil && !commandIsOpen && consentRequests.isEmpty
  }

  @discardableResult
  func toggleLibraryDrawer() -> Bool {
    guard canUseLibraryDrawer else { return false }
    if libraryDrawerSection != nil {
      closeLibraryDrawer()
      return true
    }
    return showLibraryDrawer(.spaces)
  }

  @discardableResult
  func showLibraryDrawer(_ section: LibraryDrawerSection) -> Bool {
    guard canUseLibraryDrawer else { return false }
    dismissPageFind()
    engine?.extensionPanel = nil
    libraryDrawerSection = section
    libraryDrawerProfileID = section == .spaces ? nil : session.selectedSpace.profileID
    return true
  }

  @discardableResult
  func selectLibraryDrawerSection(_ section: LibraryDrawerSection) -> Bool {
    guard libraryDrawerSection != nil, canUseLibraryDrawer else { return false }
    libraryDrawerSection = section
    libraryDrawerProfileID = section == .spaces ? nil : session.selectedSpace.profileID
    if section != .spaces {
      engine?.runtime.refreshDownloads(forProfileID: session.selectedSpace.profileID.uuidString)
    }
    return true
  }

  func closeLibraryDrawer() {
    libraryDrawerSection = nil
    libraryDrawerProfileID = nil
  }

  @discardableResult
  func selectLibrarySpace(_ spaceID: UUID, expectedProfileID: UUID) -> Bool {
    guard canUseLibraryDrawer, libraryDrawerSection == .spaces,
      LibrarySpacesOverviewModel.canSelectSpace(
        spaceID: spaceID, profileID: expectedProfileID, in: session)
    else { return false }
    closeLibraryDrawer()
    let signpost = OSSignpostID(log: switchLog)
    os_signpost(.begin, log: switchLog, name: "SpaceSwitch", signpostID: signpost)
    defer { os_signpost(.end, log: switchLog, name: "SpaceSwitch", signpostID: signpost) }
    session.selectSpace(spaceID)
    save(deferred: true)
    return true
  }

  @discardableResult
  func selectLibraryTab(
    _ tabID: UUID, in spaceID: UUID, expectedProfileID: UUID
  ) -> Bool {
    guard canUseLibraryDrawer, libraryDrawerSection == .spaces,
      LibrarySpacesOverviewModel.canSelectTab(
        spaceID: spaceID, profileID: expectedProfileID, tabID: tabID, in: session)
    else { return false }
    closeLibraryDrawer()
    session.selectTab(tabID, in: spaceID)
    save()
    return true
  }

  @discardableResult
  func editLibrarySpace(_ spaceID: UUID, expectedProfileID: UUID) -> Bool {
    guard canUseLibraryDrawer, libraryDrawerSection == .spaces,
      LibrarySpacesOverviewModel.canEdit(
        spaceID: spaceID, profileID: expectedProfileID, in: session)
    else { return false }
    closeLibraryDrawer()
    spaceEditor = .edit(spaceID)
    return true
  }

  @discardableResult
  func createLibrarySpace() -> Bool {
    guard canUseLibraryDrawer, libraryDrawerSection == .spaces else { return false }
    closeLibraryDrawer()
    spaceEditor = .create
    return true
  }

  func showDownloads() {
    guard sheet == nil else { return }
    dismissCommand()
    dismissPageFind()
    engine?.extensionPanel = nil
    sheet = .downloads(profileID: session.selectedSpace.profileID)
    engine?.runtime.refreshDownloads(forProfileID: session.selectedSpace.profileID.uuidString)
  }

  var canReopenClosedTab: Bool {
    mayUseClosedTabs(in: session.selectedSpaceID)
      && !session.recentlyClosedTabs(in: session.selectedSpaceID).isEmpty
  }

  func showRecentlyClosed() {
    guard sheet == nil else { return }
    dismissCommand()
    dismissPageFind()
    engine?.extensionPanel = nil
    sheet = .recentlyClosed(spaceID: session.selectedSpaceID)
  }

  private func mayUseClosedTabs(in spaceID: UUID) -> Bool {
    guard session.selectedSpaceID == spaceID else { return false }
    if case .recentlyClosed(let owner) = sheet { return owner == spaceID }
    return sheet == nil
  }

  @discardableResult
  func reopenLastClosedTab() -> Bool {
    guard let entry = session.recentlyClosedTabs(in: session.selectedSpaceID).first else {
      return false
    }
    return reopenClosedTab(entry.id, in: session.selectedSpaceID)
  }

  @discardableResult
  func reopenClosedTab(_ id: UUID, in spaceID: UUID) -> Bool {
    guard mayUseClosedTabs(in: spaceID), session.reopenClosedTab(id, in: spaceID) != nil
    else { return false }
    dismissCommand()
    dismissPageFind()
    engine?.extensionPanel = nil
    if case .recentlyClosed = sheet { sheet = nil }
    save()
    return true
  }

  @discardableResult
  func clearClosedTabs(in spaceID: UUID) -> Bool {
    guard mayUseClosedTabs(in: spaceID), session.clearClosedTabs(in: spaceID) else { return false }
    save()
    return true
  }

  var canFindCurrentPage: Bool {
    sheet == nil && session.selectedPage.map { rendererFailures[$0.tab.id] == nil } == true
  }

  func showPageFind() {
    guard canFindCurrentPage, let tab = session.selectedPage?.tab else { return }
    closeLibraryDrawer()
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
    sidebarNotice = nil
    switch action {
    case .open(let url): session.open(url)
    case .space(let id):
      closeLibraryDrawer()
      let signpost = OSSignpostID(log: switchLog)
      os_signpost(.begin, log: switchLog, name: "SpaceSwitch", signpostID: signpost)
      session.selectSpace(id)
      commandIsOpen = false
      save(deferred: true)
      os_signpost(.end, log: switchLog, name: "SpaceSwitch", signpostID: signpost)
      return
    case .folder(let space, let folder): session.selectFolder(folder, in: space)
    case .favorite(let profile, let id):
      guard commandIsOpen, sheet == nil, session.selectedSpace.profileID == profile,
        session.favorites.contains(where: { $0.id == id && $0.profileID == profile })
      else { return }
      dismissCommand()
      _ = selectFavorite(id)
      return
    case .tab(let space, let tab):
      closeLibraryDrawer()
      if session.spaces.first(where: { $0.id == space })?.tabs.contains(where: { $0.id == tab })
        == true
      {
        session.selectTab(tab, in: space)
      } else if let selected = session.page(forTabID: tab),
        case .favorite(let page) = selected,
        session.spaces.first(where: { $0.id == space })?.profileID
          == session.profileID(forTabID: tab),
        session.selectFavorite(page.favoriteID, in: space)
      {
        // Favorite page identity stays window-local; selection only changes this Space.
      }
    case .reopen(let space, let tab):
      reopenClosedTab(tab, in: space)
      return
    case .bookmark(let profile, let id):
      openBookmark(id, profileID: profile)
      return
    case .history(let profile, let address):
      openHistoryEntry(address, profileID: profile)
      return
    }
    commandIsOpen = false
    save()
  }

  func cycleSpace(by offset: Int) {
    let signpost = OSSignpostID(log: switchLog)
    os_signpost(.begin, log: switchLog, name: "SpaceSwitch", signpostID: signpost)
    defer { os_signpost(.end, log: switchLog, name: "SpaceSwitch", signpostID: signpost) }
    sidebarNotice = nil
    session.cycleSpace(by: offset)
    save(deferred: true)
  }

  func closeTab(_ id: UUID) {
    if let onCloseTab {
      onCloseTab(id)
      return
    }
    nativeTabClosed(id)
  }

  func nativeTabClosed(_ id: UUID) {
    rendererFailures[id] = nil
    if let favoritePage = session.favoritePages.first(where: { $0.tab.id == id }) {
      _ = session.closeFavoritePage(favoritePage.favoriteID)
      save()
      return
    }
    session.closeTab(id)
    save()
  }

  var profileFavorites: [BrowserFavorite] {
    session.favorites(for: session.selectedSpace.profileID)
  }

  var canFavoriteCurrentPage: Bool {
    guard sheet == nil, !commandIsOpen, let page = session.selectedPage,
      case .tab(let tab) = page
    else { return false }
    return NavigationInput.isWebURL(tab.url)
  }

  @discardableResult
  func addCurrentPageAsFavorite() -> Bool {
    guard canFavoriteCurrentPage, case .tab(let tab) = session.selectedPage else { return false }
    let tabID = tab.id
    guard session.promoteTabToFavorite(tabID, in: session.selectedSpaceID) != nil else {
      return false
    }
    save()
    return true
  }

  @discardableResult
  func selectFavorite(_ id: UUID) -> Bool {
    guard sheet == nil, !commandIsOpen,
      session.favorites.contains(where: {
        $0.id == id && $0.profileID == session.selectedSpace.profileID
      }), session.selectFavorite(id, in: session.selectedSpaceID)
    else { return false }
    dismissPageFind()
    engine?.extensionPanel = nil
    save()
    return true
  }

  @discardableResult
  func removeFavorite(_ id: UUID) -> Bool {
    guard sheet == nil, !commandIsOpen,
      session.favorites.contains(where: {
        $0.id == id && $0.profileID == session.selectedSpace.profileID
      }), session.removeFavorite(id, disposition: .preserveAsTab)
    else { return false }
    save()
    return true
  }

  @ObservationIgnored var onNavigatePage: ((UUID, UUID, URL) -> Bool)?

  @discardableResult
  func resetFavorite(_ id: UUID) -> Bool {
    guard sheet == nil, !commandIsOpen,
      let favorite = session.favorites.first(where: {
        $0.id == id && $0.profileID == session.selectedSpace.profileID
      }), session.selectedSpace.profileID == favorite.profileID
    else { return false }
    let pageExisted = session.favoritePages.contains { $0.favoriteID == id }
    let wasSelected = session.selectedSpace.selectedFavoriteID == id
    guard session.selectFavorite(id, in: session.selectedSpaceID) else { return false }
    dismissPageFind()
    engine?.extensionPanel = nil
    if !pageExisted || !wasSelected { save() }
    guard let page = session.favoritePages.first(where: { $0.favoriteID == id }) else {
      return false
    }
    return onNavigatePage?(page.tab.id, favorite.profileID, favorite.originalURL) == true
  }

  @discardableResult
  func moveFavorite(_ id: UUID, before targetID: UUID?) -> Bool {
    guard sheet == nil, !commandIsOpen,
      session.moveFavorite(id, in: session.selectedSpace.profileID, before: targetID)
    else { return false }
    save()
    return true
  }

  func closeCurrentPage() {
    guard sheet == nil, !commandIsOpen, let page = session.selectedPage else { return }
    closeTab(page.tab.id)
  }

  func nativeFavoriteActivated(_ id: UUID, profileID: UUID) -> Bool {
    guard session.selectedSpace.profileID == profileID,
      let page = session.favoritePages.first(where: { $0.tab.id == id }),
      session.profileID(forTabID: id) == profileID,
      session.selectFavorite(page.favoriteID, in: session.selectedSpaceID)
    else { return false }
    save()
    return true
  }

  func nativeRendererGone(_ id: UUID, profileID: UUID, status: String, exitCode: Int) {
    guard status != "normal", session.profileID(forTabID: id) == profileID,
      let tab = session.page(forTabID: id)?.tab
    else { return }
    rendererFailures[id] = RendererFailure(
      profileID: profileID, tabID: id, pageURL: tab.url, status: status, exitCode: exitCode)
    if pageFind?.tabID == id { dismissPageFind() }
    for request in consentRequests where request.tabID == id {
      resolveConsent(request.id, accepted: false)
    }
  }

  func nativeDocumentCommitted(_ id: UUID, profileID: UUID) {
    guard rendererFailures[id]?.profileID == profileID else { return }
    rendererFailures[id] = nil
  }

  func nativePageLoading(_ id: UUID, loading: Bool) {
    guard var failure = rendererFailures[id], failure.reloading else { return }
    if loading { failure.loadingStarted = true }
    if !loading && failure.loadingStarted {
      // A stopped or failed navigation can finish without committing a replacement document.
      failure.reloading = false
      failure.loadingStarted = false
    }
    rendererFailures[id] = failure
  }

  var canReloadCurrentPage: Bool {
    guard sheet == nil, !commandIsOpen, let tab = session.selectedPage?.tab else {
      return false
    }
    return rendererFailures[tab.id]?.reloading != true && onReloadPage != nil
  }

  func canReloadFailure(_ id: UUID) -> Bool {
    guard let tab = session.selectedPage?.tab,
      let failure = rendererFailures[tab.id], failure.id == id,
      failure.profileID == session.selectedSpace.profileID
    else { return false }
    return canReloadCurrentPage
  }

  @discardableResult
  func reloadFailedPage(_ id: UUID) -> Bool {
    guard canReloadFailure(id) else { return false }
    return reloadCurrentPage()
  }

  @discardableResult
  func reloadCurrentPage() -> Bool {
    guard canReloadCurrentPage, let tab = session.selectedPage?.tab else { return false }
    dismissPageFind()
    engine?.extensionPanel = nil
    let previous = rendererFailures[tab.id]
    if var failure = previous {
      failure.reloading = true
      failure.loadingStarted = false
      rendererFailures[tab.id] = failure
    }
    guard onReloadPage?(tab.id, session.selectedSpace.profileID) == true else {
      if rendererFailures[tab.id]?.id == previous?.id { rendererFailures[tab.id] = previous }
      return false
    }
    return true
  }

  func nativeTabChanged(_ id: UUID, url: URL, title: String) {
    if session.favoritePages.contains(where: { $0.tab.id == id }),
      let profileID = session.profileID(forTabID: id)
    {
      nativeFavoritePageChanged(id, profileID: profileID, url: url, title: title)
    } else if session.updateTab(id, url: url, title: title) {
      save()
    }
  }

  func nativeFavoritePageChanged(_ id: UUID, profileID: UUID, url: URL, title: String) {
    guard let page = session.favoritePages.first(where: { $0.tab.id == id }),
      session.profileID(forTabID: id) == profileID,
      session.updateFavoritePage(page.favoriteID, url: url, title: title)
    else { return }
    save()
  }

  /// Engine activation can reveal another Space using this profile, never another account.
  @discardableResult
  func nativeTabActivated(_ id: UUID, profileID: UUID) -> Bool {
    guard session.selectedSpace.profileID == profileID,
      let owner = session.spaces.first(where: {
        $0.profileID == profileID && $0.tabs.contains { $0.id == id }
      })
    else { return false }
    guard session.selectedSpaceID != owner.id || owner.selectedTabID != id else { return true }
    session.selectTab(id, in: owner.id)
    save()
    return true
  }

  func nativeTabOpened(_ tab: BrowserTab, profileID: UUID, openerID: UUID?, foreground: Bool)
    -> Bool
  {
    let previousSpaceID = session.selectedSpaceID
    let mayForeground = foreground && session.selectedSpace.profileID == profileID
    let favoriteOpenerSpace: UUID? = openerID.flatMap { opener -> UUID? in
      guard session.profileID(forTabID: opener) == profileID,
        let favoritePage = session.favoritePages.first(where: { $0.tab.id == opener })
      else { return nil }
      return session.spaces.first(where: {
        $0.id == session.selectedSpaceID && $0.profileID == profileID
      })?.id ?? session.spaces.first(where: {
        $0.profileID == profileID && $0.selectedFavoriteID == favoritePage.favoriteID
      })?.id ?? session.spaces.first { $0.profileID == profileID }?.id
    }
    if let favoriteOpenerSpace { session.selectSpace(favoriteOpenerSpace) }
    guard
      session.insertNativeTab(
        tab, profileID: profileID,
        openerID: favoriteOpenerSpace == nil ? openerID : nil, foreground: mayForeground)
        != nil
    else {
      if !mayForeground { session.selectSpace(previousSpaceID) }
      return false
    }
    if !mayForeground { session.selectSpace(previousSpaceID) }
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

  @discardableResult
  func requestExternalApp(_ request: ExternalAppRequest) -> Bool {
    enqueueConsent(.externalApp(request))
  }

  func resolveExternalApp(_ id: String, accepted: Bool) {
    resolveConsent("external-\(id)", accepted: accepted)
  }

  private func enqueueConsent(_ request: BrowserSheet) -> Bool {
    guard request.isConsent, let tab = request.tabID, rendererFailures[tab] == nil,
      request.matches(session), consentRequests.count < 10,
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
    var allow =
      accepted && presented && request.matches(session)
      && request.tabID.map { rendererFailures[$0] == nil } == true
    if case .externalApp(let external) = request { allow = allow && external.canOpen }
    switch request {
    case .extensionInstall(let request): onInstallDecision?(request.id, allow)
    case .websiteMedia(let request): onWebsiteMediaDecision?(request.id, allow)
    case .externalApp(let request): onExternalAppDecision?(request.id, allow)
    case .space, .downloads, .folder, .recentlyClosed, .library, .bookmarkEditor: break
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
  func moveSpace(_ id: UUID, before target: UUID?) -> Bool {
    guard sheet == nil, session.moveSpace(id, before: target) else { return false }
    sidebarNotice = nil
    save()
    return true
  }

  @discardableResult
  func moveTab(
    _ id: UUID, from source: UUID, to destination: UUID, before target: UUID? = nil,
    pinned: Bool? = nil, folderID: UUID? = nil
  ) -> Bool {
    guard sheet == nil else { return false }
    if let origin = session.spaces.first(where: { $0.id == source }),
      let targetSpace = session.spaces.first(where: { $0.id == destination }),
      origin.profileID != targetSpace.profileID
    {
      sidebarNotice = "Tabs can move only between spaces sharing a profile."
      return false
    }
    guard
      session.moveTab(
        id, from: source, to: destination, before: target, pinned: pinned, folderID: folderID)
    else {
      return false
    }
    sidebarNotice = nil
    save()
    return true
  }

  @discardableResult
  func acceptSidebarDrop(
    _ item: SidebarTransfer, into space: UUID, before targetTab: UUID? = nil,
    pinned: Bool? = nil, beforeSpace: UUID? = nil, folderID: UUID? = nil, beforeFolder: UUID? = nil
  ) -> Bool {
    guard session.spaces.contains(where: { $0.id == space }) else { return false }
    switch item {
    case .tab(let sessionID, let source, let tab):
      guard sessionID == dragSessionID else { return false }
      return moveTab(
        tab, from: source, to: space, before: targetTab, pinned: pinned, folderID: folderID)
    case .space(let sessionID, let id):
      guard sessionID == dragSessionID, targetTab == nil, pinned == nil, folderID == nil,
        beforeFolder == nil
      else { return false }
      return moveSpace(id, before: beforeSpace)
    case .folder(let sessionID, let source, let folder):
      guard sessionID == dragSessionID, targetTab == nil, pinned != false else { return false }
      return moveFolder(folder, from: source, to: space, parentID: folderID, before: beforeFolder)
    }
  }

  func showFolderEditor(_ route: FolderEditorRoute) {
    guard sheet == nil, route.matches(session) else { return }
    dismissCommand()
    dismissPageFind()
    engine?.extensionPanel = nil
    sheet = .folder(route)
  }

  private func mayEditFolders(in space: UUID) -> Bool {
    guard session.selectedSpaceID == space else { return false }
    if case .folder(let route) = sheet { return route.spaceID == space && route.matches(session) }
    return sheet == nil
  }

  @discardableResult
  func createFolder(name: String, in space: UUID, parentID: UUID? = nil) -> UUID? {
    guard mayEditFolders(in: space),
      let id = session.addFolder(name: name, in: space, parentID: parentID)
    else { return nil }
    save()
    return id
  }

  @discardableResult
  func renameFolder(_ id: UUID, in space: UUID, name: String) -> Bool {
    guard mayEditFolders(in: space), session.renameFolder(id, in: space, name: name) else {
      return false
    }
    save()
    return true
  }

  @discardableResult
  func removeFolder(_ id: UUID, in space: UUID) -> Bool {
    guard mayEditFolders(in: space), session.removeFolder(id, in: space) else { return false }
    save()
    return true
  }

  func toggleFolder(_ id: UUID, in space: UUID) {
    guard sheet == nil, session.selectedSpaceID == space, session.toggleFolder(id, in: space) else {
      return
    }
    save()
  }

  @discardableResult
  func moveFolder(
    _ id: UUID, from source: UUID, to destination: UUID, parentID: UUID? = nil,
    before target: UUID? = nil
  ) -> Bool {
    guard sheet == nil else { return false }
    sidebarNotice = nil
    if let origin = session.spaces.first(where: { $0.id == source }),
      let targetSpace = session.spaces.first(where: { $0.id == destination })
    {
      if origin.profileID != targetSpace.profileID {
        sidebarNotice = "Folders can move only between spaces sharing a profile."
        return false
      }
      if source == destination,
        targetSpace.folderPath(to: parentID).contains(where: { $0.id == id })
      {
        sidebarNotice = "A folder cannot be moved inside itself."
        return false
      }
    }
    guard session.moveFolder(id, from: source, to: destination, parentID: parentID, before: target)
    else { return false }
    save()
    return true
  }

  @discardableResult
  func createSpace(
    name: String, sharingProfile profileID: UUID?, tint: SpaceTint,
    customRGB: SpaceRGBColor? = nil
  ) -> Bool {
    guard
      session.addSpace(
        name: name, sharingProfile: profileID, tint: tint, customRGB: customRGB) != nil
    else {
      return false
    }
    save()
    return true
  }

  @discardableResult
  func updateSpace(
    _ id: UUID, name: String, tint: SpaceTint, customRGB: SpaceRGBColor? = nil
  ) -> Bool {
    guard session.updateSpace(id, name: name, tint: tint, customRGB: customRGB) else {
      return false
    }
    save()
    return true
  }

  @discardableResult
  func removeSpace(_ id: UUID) -> Bool {
    guard session.removeSpace(id, favoriteDisposition: .closePage) else { return false }
    save()
    return true
  }

  func spaceRemovalImpact(_ id: UUID) -> SpaceRemovalImpact {
    onSpaceRemovalImpact?(id)
      ?? {
        guard let space = session.spaces.first(where: { $0.id == id }) else {
          return SpaceRemovalImpact(tabs: 0, windows: 1)
        }
        let lastProfileSpace = session.spaces.filter { $0.profileID == space.profileID }.count == 1
        let favorites =
          lastProfileSpace
          ? session.favoritePages.filter {
            session.profileID(forTabID: $0.tab.id) == space.profileID
          }.count
          : 0
        return SpaceRemovalImpact(tabs: space.tabs.count, windows: 1, favoritePages: favorites)
      }()
  }

  private func save(deferred: Bool = false) {
    reconcileTransientState()
    defer { onSessionChanged?() }
    if let managedSave {
      let result = managedSave(session, deferred)
      session = result.session
      storageNotice = result.notice
      reconcileTransientState()
      return
    }
    guard maySave else { return }
    guard let sessionFile else { return }
    let snapshot = session
    if deferred {
      snapshotScheduler.schedule({ try sessionFile.save(snapshot) }) { [weak self] error in
        self?.storageNotice = error.map { "Changes could not be saved. \($0)" }
      }
      return
    }
    do {
      try snapshotScheduler.writeNow { try sessionFile.save(snapshot) }
      storageNotice = nil
    } catch {
      storageNotice = "Changes could not be saved. \(error.localizedDescription)"
    }
  }

  private func reconcileTransientState() {
    rendererFailures = rendererFailures.filter { $0.value.belongs(to: session) }
    if !canUseLibraryDrawer {
      closeLibraryDrawer()
    } else if libraryDrawerSection == .spaces {
      libraryDrawerProfileID = nil
    } else if libraryDrawerSection != nil,
      libraryDrawerProfileID != session.selectedSpace.profileID
    {
      closeLibraryDrawer()
    }
    if case .library(let profile, _) = sheet, profile != session.selectedSpace.profileID {
      sheet = nil
    }
    if case .bookmarkEditor(let route) = sheet, !route.matches(self) { sheet = nil }
    if case .recentlyClosed(let space) = sheet, space != session.selectedSpaceID { sheet = nil }
    if case .folder(let route) = sheet, !route.matches(session) { sheet = nil }
    if case .downloads(let profile) = sheet, profile != session.selectedSpace.profileID {
      sheet = nil
    }
    if let current = pageFind, !current.matches(session) { dismissPageFind() }
    for request in consentRequests where !request.matches(session) {
      resolveConsent(request.id, accepted: false)
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

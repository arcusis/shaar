// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
  var tabDescription: String { ShellL10n.plural("%d tabs", count: tabs) }

  private var favoriteImpact: String {
    guard favoritePages > 0 else { return "" }
    return ShellL10n.format(
      " and %@",
      arguments: [.string(ShellL10n.plural("%d Favorite pages", count: favoritePages))])
  }

  var message: String {
    windows > 1
      ? ShellL10n.format(
        "This space will be deleted from all %@, closing %@%@. Its profile is kept.",
        arguments: [
          .string(ShellL10n.plural("%d windows", count: windows)), .string(tabDescription),
          .string(favoriteImpact),
        ])
      : ShellL10n.format(
        "Tabs in this space will close%@. Its profile is kept.",
        arguments: [.string(favoriteImpact)])
  }
}

@MainActor @Observable
final class BrowserStore {
  var session: BrowserSession
  private(set) var isPrivate = false
  private var permissionFrames: [UUID: String] = [:]
  /// Tabs Chromium has discarded or frozen. Not saved with the session.
  private(set) var sleepingTabIDs: Set<UUID> = []
  private var permissionFrameOrigins: [UUID: URL] = [:]
  var privatePage: PrivatePageSession?
  var splitTabRecency: [UUID] = []
  var pendingSplitPlacement: SplitPlacement?
  var sidebarDrag: SidebarTransfer?
  var tabDrag: TabDrag?
  @ObservationIgnored var sidebarDragCleanupTask: Task<Void, Never>?
  @ObservationIgnored var tabDragCleanupTask: Task<Void, Never>?
  let dragSessionID = UUID()
  let library = BrowserLibraryModel()
  private(set) var sidebarNotice: String?
  var commandIsOpen = false

  var commandQuery = "" {
    didSet {
      if let keyword = commandProviderKeyword,
        !commandQuery.lowercased().hasPrefix(keyword + " ")
      {
        commandProviderKeyword = nil
      }
      resetCommandSelection()
    }
  }
  private(set) var commandProviderKeyword: String?
  var commandEditsCurrentURL = false
  private(set) var commandSelectedRow = CommandSelection()
  var commandFilter: CommandFilter? {
    didSet {
      if commandFilter != .actions { commandProviderKeyword = nil }
      resetCommandSelection()
    }
  }
  var sidebarIsVisible = true
  private(set) var pageFind: PageFindState?
  private(set) var rendererFailures: [UUID: RendererFailure] = [:]
  @ObservationIgnored private var requestedTabCloses: Set<UUID> = []
  var sheet: BrowserSheet? {
    didSet {
      if sheet != nil { closeLibraryDrawer() }
    }
  }
  private(set) var libraryDrawerSection: LibraryDrawerSection?
  private(set) var libraryDrawerProfileID: UUID?
  var spaceEditorFocus: SpaceEditorFocus = .name
  /// Space a menu asked to delete; the window shows the confirmation.
  var spacePendingDeletion: UUID?
  /// Space a menu asked to give a new profile; the window shows the name prompt.
  var spaceEditor: SpaceEditorRoute? {
    get {
      if case .space(let route) = sheet { return route }
      return nil
    }
    set {
      if sheet?.isConsent == true { return }
      if newValue != nil {
        dismissCommand()
        dismissPageFind()
      }
      sheet = newValue.map(BrowserSheet.space)
    }
  }
  private var consentRequests: [BrowserSheet] = []
  private var desktopCaptureSources: [String: Set<String>] = [:]
  var installationRequests: [ExtensionInstallRequest] {
    consentRequests.compactMap {
      if case .extensionInstall(let request) = $0 { return request }
      return nil
    }
  }
  var websitePermissionRequests: [WebsitePermissionRequest] {
    consentRequests.compactMap {
      if case .websitePermission(let request) = $0 { return request }
      return nil
    }
  }
  var externalAppRequests: [ExternalAppRequest] {
    consentRequests.compactMap {
      if case .externalApp(let request) = $0 { return request }
      return nil
    }
  }
  var deviceChooserRequests: [DeviceChooserRequest] {
    consentRequests.compactMap {
      if case .deviceChooser(let request) = $0 { return request }
      return nil
    }
  }
  private(set) var storageNotice: String?

  @ObservationIgnored private let sessionFile: SessionFile?
  @ObservationIgnored var preferences = BrowserPreferencesStore()
  @ObservationIgnored private var managedSave: ((BrowserSession, Bool) -> ManagedSessionSaveResult)?
  @ObservationIgnored private let snapshotScheduler = SnapshotSaveScheduler()
  @ObservationIgnored private let switchLog = OSLog(
    subsystem: "com.arcusis.browser", category: "SpaceSwitch")
  @ObservationIgnored private var maySave = true
  @ObservationIgnored var engine: BrowserEngine?
  @ObservationIgnored var faviconCache: FaviconCache?
  /// Maps a window-local pinned tab to the shared pin definition every window restores.
  @ObservationIgnored var sharedPinID: ((UUID) -> UUID?)?
  @ObservationIgnored var onSessionChanged: (() -> Void)?
  @ObservationIgnored var onTransferTabFromAnotherWindow:
    ((UUID, UUID, UUID, UUID, UUID?, Bool?, UUID?) -> Bool)?
  @ObservationIgnored var onCloseTab: ((UUID) -> Void)?
  /// The host's menu commands for the launcher's Actions; nil hides Actions.
  @ObservationIgnored var launcherActions: LauncherActions?
  @ObservationIgnored private var commandSectionsCache: CommandSectionsCache?
  @ObservationIgnored var onInstallDecision: ((String, Bool) -> Void)?
  @ObservationIgnored var onWebsitePermissionDecision: ((String, Bool) -> Void)?
  @ObservationIgnored var onDesktopCaptureDecision: ((String, String?) -> Void)?
  @ObservationIgnored var onWebShareDecision: ((String, WebShareOutcome) -> Void)?
  @ObservationIgnored var onPrintDecision: ((String, Bool) -> Void)?
  @ObservationIgnored var onExternalAppDecision: ((String, Bool) -> Void)?
  @ObservationIgnored var onDeviceChooserDecision: ((DeviceChooserRequest, Int?) -> Void)?
  @ObservationIgnored var onFindRequest: ((PageFindState, Bool) -> Bool)?
  @ObservationIgnored var onStopFinding: ((UUID) -> Void)?
  @ObservationIgnored var onNavigatePage: ((UUID, UUID, URL) -> Bool)?
  @ObservationIgnored var onReloadPage: ((UUID, UUID, PageReloadMode) -> Bool)?
  /// Sends a media command to a live tab; false when the engine cannot deliver it.
  @ObservationIgnored var onMediaCommand: ((UUID, MediaCommand) -> Bool)?
  /// A site's automatic picture-in-picture setting changed for a profile.
  @ObservationIgnored var onAutomaticPictureInPictureChanged: ((String, UUID) -> Void)?
  /// Media playing in this window's tabs.
  let media = MediaPlaybackModel()
  @ObservationIgnored var onSetSpaceProfile: ((UUID, UUID) -> Bool)?
  /// Opens New Profile onboarding for a Space; nil when no host can present it.
  @ObservationIgnored var onNewProfile: ((UUID) -> Void)?
  @ObservationIgnored var onSpaceRemovalImpact: ((UUID) -> SpaceRemovalImpact)?
  @ObservationIgnored private var presentedConsentID: String?

  isolated deinit {
    sidebarDragCleanupTask?.cancel()
    tabDragCleanupTask?.cancel()
  }

  init(sessionFile: SessionFile? = nil, session: BrowserSession = .fresh()) {
    self.sessionFile = sessionFile
    self.session = session
    let restored: BrowserSession?
    do {
      restored = try sessionFile?.load()
    } catch {
      maySave = false
      storageNotice =
        ShellL10n.string(
          "Saved session could not be restored. The original file is preserved; changes in this window will not be saved."
        )
      return
    }
    if let restored {
      self.session = restored
    } else {
      writeLaunchSnapshot()
    }
  }

  init(privateSession: BrowserSession) {
    sessionFile = nil
    session = privateSession
    isPrivate = true
  }

  /// The first snapshot is a launch checkpoint, written before any change is scheduled.
  private func writeLaunchSnapshot() {
    guard let sessionFile else { return }
    do {
      try sessionFile.save(session)
    } catch {
      storageNotice = Self.saveNotice(failure: error.localizedDescription)
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
    discardReassignedSpacePages(from: session, to: value)
    session = value
    storageNotice = notice
    reconcileTransientState()
    if changed { onSessionChanged?() }
  }

  /// Computed once per change of query, filter, session or library, not on every read.
  var commandSections: [CommandSection] {
    let key = commandSectionsKey()
    if let cache = commandSectionsCache, cache.key == key { return cache.sections }
    let sections = CommandLauncher.sections(
      for: key.query, filter: key.filter, in: key.session, sources: key.sources)
    commandSectionsCache = CommandSectionsCache(key: key, sections: sections)
    return sections
  }

  private func commandSectionsKey() -> CommandSectionsKey {
    let profile = session.selectedSpace.profileID
    let sources = CommandSources(
      bookmarks: library.bookmarks[profile]?.items ?? [], history: library.history[profile] ?? [],
      commands: launcherActions?.available() ?? [],
      searchEngine: preferences.searchEngine(for: profile),
      providerSearch: commandProviderKeyword == nil ? nil : commandSearchProvider)
    return CommandSectionsKey(
      query: commandQuery, filter: commandFilter, session: session, sources: sources)
  }

  var results: [CommandResult] { commandSections.results }

  /// Index of the selected row in the current results, following the row if it moved.
  var commandSelection: Int { commandSelectedRow.index(in: results) }
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
    commandProviderKeyword = nil
    commandFilter = nil
    pendingSplitPlacement = nil
    commandIsOpen = true
  }

  func showAddressEditor(tabID: UUID? = nil) {
    showCommand()
    guard
      let url = tabID.flatMap({ session.page(forTabID: $0)?.tab.url })
        ?? session.selectedPage?.tab.url
    else { return }
    commandEditsCurrentURL = true
    commandQuery = url.absoluteString
  }

  func dismissCommand() {
    commandIsOpen = false
    pendingSplitPlacement = nil
  }

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
    return showLibraryDrawer(isPrivate ? .spaces : .downloads)
  }

  @discardableResult
  func showLibraryDrawer(_ section: LibraryDrawerSection) -> Bool {
    if isPrivate && section != .spaces { return false }
    guard canUseLibraryDrawer else { return false }
    dismissPageFind()
    engine?.extensionPanel = nil
    libraryDrawerSection = section
    libraryDrawerProfileID = section == .spaces ? nil : session.selectedSpace.profileID
    return true
  }

  @discardableResult
  func selectLibraryDrawerSection(_ section: LibraryDrawerSection) -> Bool {
    if isPrivate && section != .spaces { return false }
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
    measureSpaceSwitch {
      session.selectSpace(spaceID)
      save(deferred: true)
    }
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
    guard !isPrivate else { return }
    guard sheet == nil else { return }
    dismissCommand()
    dismissPageFind()
    engine?.extensionPanel = nil
    sheet = .downloads(profileID: session.selectedSpace.profileID)
    engine?.runtime.refreshDownloads(forProfileID: session.selectedSpace.profileID.uuidString)
  }

  var canFindCurrentPage: Bool {
    sheet == nil && session.selectedPage.map { rendererFailures[$0.tab.id] == nil } == true
  }

  func showPageFind() {
    guard canFindCurrentPage, let tab = session.selectedPage?.tab else { return }
    closeLibraryDrawer()
    dismissCommand()
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
    if !current.unavailable,
      current.query.compare(query, options: .caseInsensitive) == .orderedSame
    {
      current.query = query
      pageFind = current
      return
    }
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
    } else if onFindRequest?(current, forward) != true {
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
    let results = results
    guard !results.isEmpty else { return }
    let index = commandSelectedRow.index(in: results) + amount
    commandSelectedRow = CommandSelection(index: index, in: results)
  }

  /// Selects the default row: the first row of the current results.
  private func resetCommandSelection() {
    commandSelectedRow = CommandSelection(index: 0, in: results)
  }

  func cycleCommandFilter(by offset: Int) {
    commandFilter = CommandFilter.cycled(from: commandFilter, by: offset)
  }

  private var commandSearchProvider: CommandSearchProvider? {
    guard !isPrivate,
      let account = preferences.accounts(for: session.selectedSpace.profileID).first
    else { return nil }
    switch account.provider {
    case .google: return .google
    case .microsoft: return .microsoft
    case .apple: return nil
    }
  }

  @discardableResult
  func activateCommandProviderKeyword() -> Bool {
    let keyword = commandQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let provider = commandSearchProvider,
      CommandProviderSearch.supports(keyword: keyword, provider: provider)
    else { return false }
    commandProviderKeyword = keyword
    commandFilter = .actions
    commandQuery = keyword + " "
    return true
  }

  func acceptCommand() {
    guard let result = selectedCommandResult else { return }
    perform(result.action)
  }

  var selectedCommandResult: CommandResult? {
    let results = results
    let index = commandSelectedRow.index(in: results)
    return results.indices.contains(index) ? results[index] : nil
  }

  func perform(_ action: CommandAction) {
    sidebarNotice = nil
    switch action {
    case .open(let url), .providerSearch(let url):
      if let id = session.open(url) { placePendingSplitPane(id) }
    case .space(let id):
      closeLibraryDrawer()
      measureSpaceSwitch {
        session.selectSpace(id)
        dismissCommand()
        save(deferred: true)
      }
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
    case .command(let name):
      dismissCommand()
      launcherActions?.run(name)
      return
    }
    dismissCommand()
    save()
  }

  var canCycleSpace: Bool { session.spaces.count > 1 }

  func cycleSpace(by offset: Int) {
    guard canCycleSpace else { return }
    measureSpaceSwitch {
      sidebarNotice = nil
      pendingSplitPlacement = nil
      session.cycleSpace(by: offset)
      save(deferred: true)
    }
  }

  /// Brackets a Space switch with a signpost so Instruments can time it.
  private func measureSpaceSwitch(_ change: () -> Void) {
    let signpost = OSSignpostID(log: switchLog)
    os_signpost(.begin, log: switchLog, name: "SpaceSwitch", signpostID: signpost)
    defer { os_signpost(.end, log: switchLog, name: "SpaceSwitch", signpostID: signpost) }
    change()
  }

  func closeTab(_ id: UUID) {
    guard session.page(forTabID: id) != nil else { return }
    guard requestedTabCloses.insert(id).inserted else { return }
    if let onCloseTab {
      onCloseTab(id)
      return
    }
    nativeTabClosed(id)
  }

  func clearTodayTabs(in spaceID: UUID) {
    guard session.selectedSpaceID == spaceID,
      let space = session.spaces.first(where: { $0.id == spaceID })
    else { return }
    for tab in space.tabs where !tab.isPinned { closeTab(tab.id) }
  }

  func applyTidyGroups(_ groups: [SidebarTidyGroup], in spaceID: UUID) {
    guard session.selectedSpaceID == spaceID, sheet == nil,
      let space = session.spaces.first(where: { $0.id == spaceID })
    else { return }
    var todayIDs: Set<UUID> = []
    for tab in space.tabs where !tab.isPinned { todayIDs.insert(tab.id) }
    let byTopic = Dictionary(grouping: groups) {
      $0.topic.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let combined = byTopic.map {
      SidebarTidyGroup(topic: $0.key, tabIDs: $0.value.flatMap(\.tabIDs))
    }.sorted { $0.topic.localizedStandardCompare($1.topic) == .orderedAscending }
    let tabsByID = Dictionary(uniqueKeysWithValues: space.tabs.map { ($0.id, $0) })
    let foldersByID = Dictionary(uniqueKeysWithValues: space.folders.map { ($0.id, $0) })
    var tabIDsByFolderID: [UUID: Set<UUID>] = [:]
    for tab in space.tabs {
      if let folderID = tab.folderID { tabIDsByFolderID[folderID, default: []].insert(tab.id) }
    }
    var handled: Set<UUID> = []
    for group in combined where group.tabIDs.count > 1 {
      let ids = Set(group.tabIDs)
      guard ids.isSubset(of: todayIDs), ids.isDisjoint(with: handled) else { continue }
      if tidyGroupIsCurrent(
        group, ids: ids, tabsByID: tabsByID, foldersByID: foldersByID,
        tabIDsByFolderID: tabIDsByFolderID)
      {
        handled.formUnion(ids)
        continue
      }
      guard let folder = createFolder(name: group.topic, in: spaceID, section: .today) else {
        continue
      }
      for id in group.tabIDs {
        _ = moveTab(id, from: spaceID, to: spaceID, folderID: folder)
      }
      handled.formUnion(ids)
    }
  }

  private func tidyGroupIsCurrent(
    _ group: SidebarTidyGroup, ids: Set<UUID>, tabsByID: [UUID: BrowserTab],
    foldersByID: [UUID: BrowserFolder], tabIDsByFolderID: [UUID: Set<UUID>]
  ) -> Bool {
    guard let first = group.tabIDs.first,
      let folderID = tabsByID[first]?.folderID,
      let folder = foldersByID[folderID], !folder.isPinned,
      folder.name == group.topic.trimmingCharacters(in: .whitespacesAndNewlines)
    else { return false }
    return tabIDsByFolderID[folderID] == ids
  }

  func noteTabSleeping(_ id: UUID) {
    guard session.page(forTabID: id) != nil else { return }
    sleepingTabIDs.insert(id)
  }

  func noteTabAwake(_ id: UUID) {
    sleepingTabIDs.remove(id)
  }

  /// A successful wake, a wake of the tab on screen, or a wake of a closed tab
  /// drops the sleeping mark. A failed wake of a background tab keeps it.
  func resolveWake(_ id: UUID, accepted: Bool) {
    let onScreen = session.selectedPage?.tab.id == id || visiblePageIDs.contains(id)
    if accepted || onScreen || session.page(forTabID: id) == nil {
      noteTabAwake(id)
    }
  }

  func nativeTabClosed(_ id: UUID) {
    sleepingTabIDs.remove(id)
    let requested = requestedTabCloses.remove(id) != nil
    permissionFrames[id] = nil
    permissionFrameOrigins[id] = nil
    cancelDesktopCaptures(for: id)
    let page = session.page(forTabID: id)
    // WebContents destruction also reports "closed". Losing a native document
    // is not permission to delete a saved pin.
    rendererFailures[id] = nil
    if pendingSplitPlacement?.target == id { dismissCommand() }
    guard let page else { return }
    guard requested || page.tab.isPinned != true else { return }
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

  var canFavoriteCurrentPage: Bool { !commandIsOpen && currentPageAllowsFavorite }

  func canAddTabToFavorites(_ tabID: UUID, in spaceID: UUID) -> Bool {
    guard sheet == nil, !commandIsOpen, session.selectedSpaceID == spaceID,
      let tab = session.selectedSpace.tabs.first(where: { $0.id == tabID })
    else { return false }
    return NavigationInput.isWebURL(tab.url)
  }

  /// Whether the page could become a Favorite, ignoring the open launcher.
  var currentPageAllowsFavorite: Bool {
    guard sheet == nil, let page = session.selectedPage, case .tab(let tab) = page else {
      return false
    }
    return NavigationInput.isWebURL(tab.url)
  }

  @discardableResult
  func addCurrentPageAsFavorite() -> Bool {
    guard canFavoriteCurrentPage, case .tab(let tab) = session.selectedPage else { return false }
    let tabID = tab.id
    let icon = favicon(forPage: tabID)
    guard profileFavorites.count < BrowserSession.maximumFavoritesPerProfile else {
      sidebarNotice = ShellL10n.string("Favorites are full (12). Remove one to add another.")
      return false
    }
    guard session.promoteTabToFavorite(tabID, in: session.selectedSpaceID) != nil else {
      return false
    }
    save()
    carryFavicon(icon, toTab: tabID)
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
    let pageID = session.favoritePages.first { $0.favoriteID == id }?.tab.id
    let icon = pageID.flatMap { favicon(forPage: $0) }
    guard sheet == nil, !commandIsOpen,
      session.favorites.contains(where: {
        $0.id == id && $0.profileID == session.selectedSpace.profileID
      }), session.removeFavorite(id, disposition: .preserveAsTab)
    else { return false }
    save()
    if let pageID { carryFavicon(icon, toTab: pageID) }
    return true
  }

  @discardableResult
  func restoreFavoriteAsTab(
    _ id: UUID, in spaceID: UUID, before tabID: UUID? = nil,
    pinned: Bool, folderID: UUID? = nil
  ) -> Bool {
    guard sheet == nil, !commandIsOpen,
      let space = session.spaces.first(where: { $0.id == spaceID }),
      session.favorites.contains(where: { $0.id == id && $0.profileID == space.profileID }),
      let pageID = session.favoritePages.first(where: { $0.favoriteID == id })?.tab.id
    else { return false }
    let icon = favicon(forPage: pageID)
    var draft = session
    let selectedSpaceID = draft.selectedSpaceID
    guard draft.selectFavorite(id, in: spaceID),
      draft.removeFavorite(id, disposition: .preserveAsTab)
    else { return false }
    if tabID != nil || folderID != nil || pinned {
      guard
        draft.moveTab(
          pageID, from: spaceID, to: spaceID, before: tabID, pinned: pinned, folderID: folderID)
      else { return false }
    }
    draft.selectSpace(selectedSpaceID)
    session = draft
    save()
    carryFavicon(icon, toTab: pageID)
    return true
  }

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
    requestedTabCloses.remove(id)
    rendererFailures[id] = RendererFailure(
      profileID: profileID, tabID: id, pageURL: tab.url, status: status, exitCode: exitCode)
    if pageFind?.tabID == id { dismissPageFind() }
    for request in consentRequests where request.tabID == id {
      resolveConsent(request.id, accepted: false)
    }
  }

  func nativeDocumentCommitted(_ id: UUID, profileID: UUID) {
    guard session.profileID(forTabID: id) == profileID else { return }
    requestedTabCloses.remove(id)
    permissionFrames[id] = nil
    permissionFrameOrigins[id] = nil
    cancelWebSharesInvalidatedByFrame(for: id)
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
    !commandIsOpen && session.selectedPage.map { canReloadPage($0.tab.id) } == true
  }

  /// Whether the page could reload, ignoring the open launcher.
  var currentPageAllowsReload: Bool {
    guard sheet == nil, let tab = session.selectedPage?.tab else { return false }
    return canReloadPage(tab.id)
  }

  func canReloadPage(_ id: UUID) -> Bool {
    guard sheet == nil, session.profileID(forTabID: id) != nil else { return false }
    return rendererFailures[id]?.reloading != true && onReloadPage != nil
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
  func reloadCurrentPage(_ mode: PageReloadMode = .normal) -> Bool {
    guard canReloadCurrentPage, let tab = session.selectedPage?.tab else { return false }
    dismissPageFind()
    engine?.extensionPanel = nil
    let previous = rendererFailures[tab.id]
    if var failure = previous {
      failure.reloading = true
      failure.loadingStarted = false
      rendererFailures[tab.id] = failure
    }
    guard onReloadPage?(tab.id, session.selectedSpace.profileID, mode) == true else {
      if rendererFailures[tab.id]?.id == previous?.id { rendererFailures[tab.id] = previous }
      return false
    }
    return true
  }

  func nativeTabChanged(_ id: UUID, url: URL, title: String) {
    if session.page(forTabID: id)?.tab.url != url {
      permissionFrames[id] = nil
      permissionFrameOrigins[id] = nil
    }
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
    guard
      session.selectedSpaceID != owner.id || owner.selectedTabID != id
        || owner.selectedFavoriteID != nil
    else { return true }
    session.selectTab(id, in: owner.id)
    save()
    return true
  }

  @discardableResult
  func selectTabByShortcutIndex(_ index: Int) -> Bool {
    let tabs = session.selectedSpace.tabs
    guard tabs.indices.contains(index) else { return false }
    closeLibraryDrawer()
    session.selectTab(tabs[index].id, in: session.selectedSpaceID)
    save()
    return true
  }

  @discardableResult
  func selectNumberedPage(_ number: Int) -> Bool {
    let space = session.selectedSpace
    let tabs = space.tabs
    let orderedTabs = space.orderedTabs
    let favorites = session.favorites(for: space.profileID)
    let pageIDs = orderedTabs.map(\.id) + favorites.compactMap {
      session.favoritePage(for: $0.id)?.tab.id
    }
    let index = number == 9 ? pageIDs.count - 1 : number - 1
    guard pageIDs.indices.contains(index) else { return false }
    let pageID = pageIDs[index]
    if let tabIndex = tabs.firstIndex(where: { $0.id == pageID }) {
      return selectTabByShortcutIndex(tabIndex)
    }
    guard let favorite = favorites.first(where: {
      session.favoritePage(for: $0.id)?.tab.id == pageID
    }), session.selectFavorite(favorite.id, in: space.id) else { return false }
    closeLibraryDrawer()
    dismissPageFind()
    engine?.extensionPanel = nil
    save()
    return true
  }

  @discardableResult
  func selectAdjacentTab(by offset: Int) -> Bool {
    let space = session.selectedSpace
    let tabs = space.orderedTabs
    guard tabs.count > 1, let selectedID = space.selectedTabID,
      let index = tabs.firstIndex(where: { $0.id == selectedID })
    else { return false }
    let next = (index + offset % tabs.count + tabs.count) % tabs.count
    guard let rawIndex = space.tabs.firstIndex(where: { $0.id == tabs[next].id }) else {
      return false
    }
    return selectTabByShortcutIndex(rawIndex)
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
  func openDevToolsRequestedTab(_ url: URL, sourceTabID: UUID, profileID: UUID) -> Bool {
    guard session.profileID(forTabID: sourceTabID) == profileID,
      NavigationInput.isWebURL(url) || NavigationInput.isDevToolsFrontendURL(url),
      session.insertNativeTab(
        BrowserTab(url: url), profileID: profileID, openerID: sourceTabID, foreground: true) != nil
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
  func requestWebsitePermission(_ request: WebsitePermissionRequest) -> Bool {
    enqueueConsent(.websitePermission(request))
  }

  @discardableResult
  func requestDesktopCapture(_ request: DesktopCaptureRequest) -> Bool {
    if let frameID = permissionFrames[request.tabID], frameID != request.frameID {
      return false
    }
    if let origin = permissionFrameOrigins[request.tabID], origin != request.requestingOrigin {
      return false
    }
    guard enqueueConsent(.desktopCapture(request)) else { return false }
    rememberPermissionFrame(
      request.tabID, frameID: request.frameID, origin: request.requestingOrigin)
    return true
  }

  @discardableResult
  func requestWebShare(_ request: WebShareRequest) -> Bool {
    guard webShareRequestIsCurrent(request) else { return false }
    return enqueueConsent(.webShare(request))
  }

  private func webShareRequestIsCurrent(_ request: WebShareRequest) -> Bool {
    guard let frameID = permissionFrames[request.tabID],
      let origin = permissionFrameOrigins[request.tabID],
      request.matches(session, frameID: frameID, origin: origin)
    else { return false }
    return true
  }

  func canPresentWebShare(_ request: WebShareRequest) -> Bool {
    sheet?.id == request.sheetID
      && presentedConsentID == request.sheetID
      && webShareRequestIsCurrent(request)
      && rendererFailures[request.tabID] == nil
  }

  @discardableResult
  func requestPrint(_ request: PrintRequest) -> Bool {
    guard printRequestIsCurrent(request) else { return false }
    return enqueueConsent(.print(request))
  }

  private func printRequestIsCurrent(_ request: PrintRequest) -> Bool {
    guard let frameID = permissionFrames[request.tabID],
      let origin = permissionFrameOrigins[request.tabID]
    else { return false }
    return request.matches(session, frameID: frameID, origin: origin)
  }

  func resolvePrint(_ id: String, accepted: Bool) {
    let sheetID = "print-\(id)"
    guard let request = consentRequests.first(where: { $0.id == sheetID }),
      case .print(let printRequest) = request
    else { return }
    let presented = sheet?.id == sheetID && presentedConsentID == sheetID
    consentRequests.removeAll { $0.id == sheetID }
    if presentedConsentID == sheetID { presentedConsentID = nil }
    if presented { sheet = nil }
    let allow =
      presented && accepted
      && printRequestIsCurrent(printRequest)
      && rendererFailures[printRequest.tabID] == nil
    onPrintDecision?(id, allow)
    presentNextConsent()
  }

  func resolveWebShare(_ id: String, outcome: WebShareOutcome) {
    let sheetID = "web-share-\(id)"
    guard let request = consentRequests.first(where: { $0.id == sheetID }),
      case .webShare(let share) = request
    else { return }
    let presented = sheet?.id == sheetID && presentedConsentID == sheetID
    consentRequests.removeAll { $0.id == sheetID }
    if presentedConsentID == sheetID { presentedConsentID = nil }
    if presented { sheet = nil }
    let accepted =
      presented
      && outcome == .shared
      && webShareRequestIsCurrent(share)
      && rendererFailures[share.tabID] == nil
    onWebShareDecision?(id, accepted ? .shared : .cancelled)
    presentNextConsent()
  }

  func resolveDesktopCapture(_ id: String, sourceID: String?) {
    let sheetID = "desktop-capture-\(id)"
    guard let request = consentRequests.first(where: { $0.id == sheetID }),
      case .desktopCapture(let capture) = request
    else { return }
    let presented = sheet?.id == sheetID && presentedConsentID == sheetID
    consentRequests.removeAll { $0.id == sheetID }
    if presentedConsentID == sheetID { presentedConsentID = nil }
    if presented { sheet = nil }
    var validSource: String?
    if let sourceID,
      DesktopCaptureSource.isValidToken(sourceID),
      desktopCaptureSources[id]?.contains(sourceID) == true,
      let sourceKind = DesktopCaptureSource.kind(forToken: sourceID), capture.allows(sourceKind)
    {
      validSource = sourceID
    }
    let valid =
      presented
      && permissionFrames[capture.tabID] != nil
      && permissionFrameOrigins[capture.tabID] != nil
      && capture.matches(
        session, frameID: permissionFrames[capture.tabID],
        origin: permissionFrameOrigins[capture.tabID])
      && rendererFailures[capture.tabID] == nil
    onDesktopCaptureDecision?(id, valid ? validSource : nil)
    desktopCaptureSources[id] = nil
    presentNextConsent()
  }

  func setDesktopCaptureSources(_ sourceIDs: [String], for id: String) {
    guard consentRequests.contains(where: { $0.id == "desktop-capture-\(id)" }),
      sourceIDs.allSatisfy(DesktopCaptureSource.isValidToken)
    else { return }
    desktopCaptureSources[id] = Set(sourceIDs)
  }

  func dismissDesktopCapture(_ id: String) {
    let sheetID = "desktop-capture-\(id)"
    guard consentRequests.contains(where: { $0.id == sheetID }) else { return }
    consentRequests.removeAll { $0.id == sheetID }
    desktopCaptureSources[id] = nil
    if presentedConsentID == sheetID {
      presentedConsentID = nil
      if sheet?.id == sheetID { sheet = nil }
    }
    presentNextConsent()
  }

  private func cancelDesktopCaptures(for tabID: UUID) {
    let requestIDs = consentRequests.compactMap { request -> String? in
      guard case .desktopCapture(let capture) = request, capture.tabID == tabID else { return nil }
      return capture.id
    }
    for requestID in requestIDs {
      resolveDesktopCapture(requestID, sourceID: nil)
    }
  }

  func rememberPermissionFrame(_ tabID: UUID, frameID: String, origin: URL? = nil) {
    permissionFrames[tabID] = frameID
    permissionFrameOrigins[tabID] = origin
    cancelWebSharesInvalidatedByFrame(for: tabID)
    cancelDesktopCapturesInvalidatedByFrame(for: tabID)
  }

  func forgetPermissionFrame(_ tabID: UUID, matching frameID: String?) {
    guard permissionFrames[tabID] == frameID else { return }
    let usedByAcceptedShare = consentRequests.contains { request in
      guard case .webShare(let share) = request else { return false }
      return share.tabID == tabID && share.frameID == frameID
    }
    let usedByPendingPrint = consentRequests.contains { request in
      guard case .print(let print) = request else { return false }
      return print.tabID == tabID && print.frameID == frameID
    }
    guard !usedByAcceptedShare, !usedByPendingPrint else { return }
    permissionFrames[tabID] = nil
    permissionFrameOrigins[tabID] = nil
    cancelWebSharesInvalidatedByFrame(for: tabID)
    cancelDesktopCapturesInvalidatedByFrame(for: tabID)
  }

  private func cancelWebSharesInvalidatedByFrame(for tabID: UUID) {
    let staleIDs = consentRequests.compactMap { request -> String? in
      guard case .webShare(let share) = request,
        share.tabID == tabID,
        !webShareRequestIsCurrent(share)
      else { return nil }
      return share.id
    }
    for id in staleIDs {
      resolveWebShare(id, outcome: .cancelled)
    }
  }

  private func cancelDesktopCapturesInvalidatedByFrame(for tabID: UUID) {
    let staleIDs = consentRequests.compactMap { request -> String? in
      guard case .desktopCapture(let capture) = request, capture.tabID == tabID else { return nil }
      let matchesCurrentFrame: Bool
      if let frameID = permissionFrames[tabID], let origin = permissionFrameOrigins[tabID] {
        matchesCurrentFrame = capture.matches(session, frameID: frameID, origin: origin)
      } else {
        matchesCurrentFrame = false
      }
      guard !matchesCurrentFrame else { return nil }
      return capture.id
    }
    for id in staleIDs {
      resolveDesktopCapture(id, sourceID: nil)
    }
  }

  func websitePermissionIsCurrent(_ request: WebsitePermissionRequest) -> Bool {
    guard request.matches(session), rendererFailures[request.tabID] == nil else { return false }
    guard let frameID = request.frameID else { return true }
    return permissionFrames[request.tabID] == frameID
  }

  func resolveWebsitePermission(_ id: String, accepted: Bool) {
    resolveConsent("permission-\(id)", accepted: accepted)
  }

  @discardableResult
  func requestExternalApp(_ request: ExternalAppRequest) -> Bool {
    enqueueConsent(.externalApp(request))
  }

  func resolveExternalApp(_ id: String, accepted: Bool) {
    resolveConsent("external-\(id)", accepted: accepted)
  }

  @discardableResult
  func requestDeviceChooser(_ request: DeviceChooserRequest) -> Bool {
    enqueueConsent(.deviceChooser(request))
  }

  func resolveDeviceChooser(_ id: String, optionIndex: Int?) {
    let sheetID = "chooser-\(id)"
    guard let request = consentRequests.first(where: { $0.id == sheetID }),
      case .deviceChooser(let chooser) = request
    else { return }
    let presented = sheet?.id == sheetID && presentedConsentID == sheetID
    consentRequests.removeAll { $0.id == sheetID }
    if presentedConsentID == sheetID { presentedConsentID = nil }
    if presented { sheet = nil }
    onDeviceChooserDecision?(
      chooser, grantedDeviceIndex(chooser, optionIndex: optionIndex, presented: presented))
    presentNextConsent()
  }

  func updateDeviceChooser(_ request: DeviceChooserRequest) -> Bool {
    guard let index = consentRequests.firstIndex(where: { $0.id == request.sheetID }),
      case .deviceChooser(let current) = consentRequests[index],
      current.matches(session), request.matches(session), current.transport == request.transport,
      current.origin == request.origin
    else { return false }
    consentRequests[index] = .deviceChooser(request)
    if sheet?.id == request.sheetID { sheet = .deviceChooser(request) }
    return true
  }

  func dismissDeviceChooserFromEngine(_ id: String) {
    let sheetID = "chooser-\(id)"
    guard consentRequests.contains(where: { $0.id == sheetID }) else { return }
    consentRequests.removeAll { $0.id == sheetID }
    if presentedConsentID == sheetID {
      presentedConsentID = nil
      if sheet?.id == sheetID { sheet = nil }
    }
    presentNextConsent()
  }

  private func grantedDeviceIndex(
    _ chooser: DeviceChooserRequest, optionIndex: Int?, presented: Bool
  ) -> Int? {
    guard presented, chooser.matches(session), rendererFailures[chooser.tabID] == nil,
      chooser.canGrant, let optionIndex
    else { return nil }
    guard chooser.options.contains(where: { $0.index == optionIndex }) else { return nil }
    return optionIndex
  }

  private func enqueueConsent(_ request: BrowserSheet) -> Bool {
    guard request.isConsent, let tab = request.tabID, rendererFailures[tab] == nil,
      request.matches(session), consentRequests.count < 10,
      !consentRequests.contains(where: { $0.id == request.id })
    else { return false }
    consentRequests.append(request)
    dismissCommand()
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
    if case .websitePermission(let permission) = request {
      allow = accepted && presented && websitePermissionIsCurrent(permission)
    }
    if case .externalApp(let external) = request { allow = allow && external.canOpen }
    switch request {
    case .extensionInstall(let request): onInstallDecision?(request.id, allow)
    case .websitePermission(let request): onWebsitePermissionDecision?(request.id, allow)
    case .desktopCapture(let request):
      desktopCaptureSources[request.id] = nil
      onDesktopCaptureDecision?(request.id, nil)
    case .webShare(let request): onWebShareDecision?(request.id, .cancelled)
    case .print(let request): onPrintDecision?(request.id, false)
    case .externalApp(let request): onExternalAppDecision?(request.id, allow)
    case .deviceChooser(let request): onDeviceChooserDecision?(request, nil)
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
    let icon = favicon(forPage: id)
    session.togglePin(id)
    save()
    carryFavicon(icon, toTab: id)
  }

  func setKeepAlive(_ enabled: Bool, for id: UUID) {
    guard session.setKeepAlive(enabled, for: id) else { return }
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
      sidebarNotice = ShellL10n.string("Tabs can move only between spaces sharing a profile.")
      return false
    }
    let icon = favicon(forPage: id)
    guard
      session.moveTab(
        id, from: source, to: destination, before: target, pinned: pinned, folderID: folderID)
    else {
      return false
    }
    sidebarNotice = nil
    save()
    carryFavicon(icon, toTab: id)
    return true
  }

  @discardableResult
  func moveTabOutsideFolder(_ id: UUID, in spaceID: UUID) -> Bool {
    guard let space = session.spaces.first(where: { $0.id == spaceID }),
      let tab = space.tabs.first(where: { $0.id == id }), tab.folderID != nil
    else { return false }
    return moveTab(id, from: spaceID, to: spaceID, pinned: tab.isPinned)
  }

  func setSidebarNotice(_ notice: String?) {
    sidebarNotice = notice
  }

  @discardableResult
  func moveSplitMemberToFolder(_ id: UUID, in space: UUID, folderID: UUID) -> Bool {
    guard
      let tab = session.spaces.first(where: { $0.id == space })?
        .tabs.first(where: { $0.id == id }),
      tab.folderID != folderID
    else { return false }
    return moveTab(id, from: space, to: space, folderID: folderID)
  }

  @discardableResult
  func acceptSidebarDrop(
    _ item: SidebarTransfer, into space: UUID, before targetTab: UUID? = nil,
    pinned: Bool? = nil, beforeSpace: UUID? = nil, folderID: UUID? = nil, beforeFolder: UUID? = nil
  ) -> Bool {
    guard sheet == nil, !commandIsOpen,
      session.spaces.contains(where: { $0.id == space })
    else { return false }
    switch item {
    case .tab(let sessionID, let source, let tab):
      if sessionID != dragSessionID {
        if isPrivate {
          sidebarNotice = ShellL10n.string("Tabs cannot move to or from a private window.")
          return false
        }
        guard
          onTransferTabFromAnotherWindow?(
            sessionID, tab, source, space, targetTab, pinned, folderID) == true
        else { return false }
        tabDrag = nil
        return true
      }
      guard
        moveTab(
          tab, from: source, to: space, before: targetTab, pinned: pinned, folderID: folderID)
      else { return false }
      tabDrag = nil
      return true
    case .split(let sessionID, let source, let split):
      guard sessionID == dragSessionID else { return false }
      if let origin = session.spaces.first(where: { $0.id == source }),
        let target = session.spaces.first(where: { $0.id == space }),
        origin.profileID != target.profileID
      {
        sidebarNotice = ShellL10n.string(
          "Split stacks can move only between spaces sharing a profile.")
        return false
      }
      guard
        session.moveSplit(
          split, from: source, to: space, before: targetTab, pinned: pinned, folderID: folderID)
      else { return false }
      sidebarNotice = nil
      tabDrag = nil
      save()
      return true
    case .favorite(let payload):
      if acceptsFavoriteDrag(payload, in: session.selectedSpaceID),
        let target = session.spaces.first(where: { $0.id == space }),
        target.profileID != payload.profileID
      {
        sidebarNotice = ShellL10n.string(
          "Favorites can move only between spaces sharing a profile.")
        return false
      }
      guard acceptsFavoriteDrag(payload, in: space, requiresSelectedSpace: false) else {
        return false
      }
      guard
        restoreFavoriteAsTab(
          payload.favoriteID, in: space, before: targetTab, pinned: pinned ?? false,
          folderID: folderID)
      else { return false }
      sidebarNotice = nil
      return true
    case .url(let url):
      guard NavigationInput.isWebURL(url) else { return false }
      var draft = session
      let selectedSpaceID = draft.selectedSpaceID
      draft.selectSpace(space)
      guard let tab = draft.open(url) else { return false }
      let moved = draft.moveTab(
        tab, from: space, to: space, before: targetTab, pinned: pinned, folderID: folderID)
      guard moved || (targetTab == nil && folderID == nil && pinned != true) else { return false }
      draft.selectSpace(selectedSpaceID)
      session = draft
      save()
      return true
    case .space(let sessionID, let id):
      guard sessionID == dragSessionID, targetTab == nil, pinned == nil, folderID == nil,
        beforeFolder == nil
      else { return false }
      return moveSpace(id, before: beforeSpace)
    case .folder(let sessionID, let source, let folder):
      guard sessionID == dragSessionID, targetTab == nil else { return false }
      return moveFolder(
        folder, from: source, to: space, parentID: folderID, before: beforeFolder, pinned: pinned)
    }
  }

  func acceptsFavoriteDrag(
    _ payload: ProfileFavoriteDrag, in spaceID: UUID, requiresSelectedSpace: Bool = true
  ) -> Bool {
    guard let space = session.spaces.first(where: { $0.id == spaceID }) else { return false }
    return payload.dragSessionID == dragSessionID && payload.profileID == space.profileID
      && payload.favoriteIDs == profileFavorites.map(\.id)
      && payload.favoriteIDs.contains(payload.favoriteID)
      && (!requiresSelectedSpace || session.selectedSpaceID == spaceID)
  }

  @discardableResult
  func acceptFavoritesDrop(_ item: SidebarTransfer, before target: UUID? = nil) -> Bool {
    guard sheet == nil, !commandIsOpen else { return false }
    let profile = session.selectedSpace.profileID
    guard target == nil || profileFavorites.contains(where: { $0.id == target }) else {
      return false
    }
    if let refusal = favoritesDropRefusal(for: item) {
      sidebarNotice = refusal
      return false
    }
    sidebarNotice = nil
    switch item {
    case .tab(let token, let source, let tab):
      let icon = favicon(forPage: tab)
      guard token == dragSessionID, source == session.selectedSpaceID,
        let page = session.selectedSpace.tabs.first(where: { $0.id == tab }),
        NavigationInput.isWebURL(page.url),
        let favorite = session.promoteTabToFavorite(tab, in: source)
      else { return false }
      if let target { _ = session.moveFavorite(favorite, in: profile, before: target) }
      tabDrag = nil
      save()
      carryFavicon(icon, toTab: tab)
      return true
    case .favorite(let payload):
      guard acceptsFavoriteDrag(payload, in: session.selectedSpaceID) else { return false }
      return moveFavorite(payload.favoriteID, before: target)
    case .url(let url):
      guard NavigationInput.isWebURL(url),
        profileFavorites.count < BrowserSession.maximumFavoritesPerProfile
      else { return false }
      perform(.open(url))
      guard addCurrentPageAsFavorite() else { return false }
      if let favorite = session.selectedSpace.selectedFavoriteID, let target {
        _ = session.moveFavorite(favorite, in: profile, before: target)
      }
    case .split, .folder, .space:
      return false
    }
    tabDrag = nil
    save()
    return true
  }

  @discardableResult
  func createFolderFromDrop(_ item: SidebarTransfer, onto target: UUID, name: String) -> UUID? {
    guard sheet == nil, !commandIsOpen,
      case .tab(let token, let source, let tab) = item, token == dragSessionID,
      source == session.selectedSpaceID, tab != target,
      let first = session.selectedSpace.tabs.first(where: { $0.id == target }), first.isPinned,
      session.selectedSpace.tabs.contains(where: { $0.id == tab }),
      !session.selectedSpace.splits.contains(where: { $0.tabIDs.contains(target) })
    else { return nil }
    var draft = session
    guard let folder = draft.addFolder(name: name, in: source, parentID: first.folderID),
      draft.moveTab(target, from: source, to: source, folderID: folder),
      draft.moveTab(tab, from: source, to: source, folderID: folder)
    else { return nil }
    session = draft
    tabDrag = nil
    save()
    return folder
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

  func createFolder(name: String, in space: UUID, section: SidebarSection, parentID: UUID? = nil)
    -> UUID?
  {
    guard mayEditFolders(in: space),
      let id = session.addFolder(name: name, in: space, section: section, parentID: parentID)
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
    before target: UUID? = nil, pinned: Bool? = nil
  ) -> Bool {
    guard sheet == nil else { return false }
    sidebarNotice = nil
    if let origin = session.spaces.first(where: { $0.id == source }),
      let targetSpace = session.spaces.first(where: { $0.id == destination })
    {
      if origin.profileID != targetSpace.profileID {
        sidebarNotice = ShellL10n.string("Folders can move only between spaces sharing a profile.")
        return false
      }
      if source == destination,
        targetSpace.folderPath(to: parentID).contains(where: { $0.id == id })
      {
        sidebarNotice = ShellL10n.string("A folder cannot be moved inside itself.")
        return false
      }
    }
    guard
      session.moveFolder(
        id, from: source, to: destination, parentID: parentID, before: target, pinned: pinned)
    else { return false }
    save()
    return true
  }

  @discardableResult
  func createSpace(
    name: String, sharingProfile profileID: UUID?, tint: SpaceTint,
    customRGB: SpaceRGBColor? = nil, symbol: String? = nil
  ) -> Bool {
    if isPrivate && profileID != session.selectedSpace.profileID { return false }
    guard
      let id = session.addSpace(
        name: name, sharingProfile: profileID, tint: tint, customRGB: customRGB)
    else {
      return false
    }
    if let symbol { _ = session.updateSpaceSymbol(id, symbol: symbol) }
    save()
    return true
  }

  @discardableResult
  func updateSpace(
    _ id: UUID, name: String, tint: SpaceTint, customRGB: SpaceRGBColor? = nil,
    symbol: String? = nil
  ) -> Bool {
    guard session.updateSpace(id, name: name, tint: tint, customRGB: customRGB) else {
      return false
    }
    if let symbol { _ = session.updateSpaceSymbol(id, symbol: symbol) }
    save()
    return true
  }

  @discardableResult
  func setSpaceProfile(_ spaceID: UUID, to profileID: UUID) -> Bool {
    if isPrivate { return false }
    if let onSetSpaceProfile { return onSetSpaceProfile(spaceID, profileID) }
    var updated = session
    guard updated.setSpaceProfile(spaceID, to: profileID) else { return false }
    discardReassignedSpacePages(from: session, to: updated)
    session = updated
    save()
    return true
  }

  private func discardReassignedSpacePages(from old: BrowserSession, to new: BrowserSession) {
    for space in old.spaces {
      guard let replacement = new.spaces.first(where: { $0.id == space.id }),
        replacement.profileID != space.profileID
      else { continue }
      engine?.discardReassignedTabs(Set(space.tabs.map(\.id)))
    }
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

  func updateMiniSession(_ update: (inout BrowserSession) -> Bool) -> Bool {
    guard update(&session) else { return false }
    save()
    return true
  }

  func save(deferred: Bool = false) {
    recordSplitTabSelection()
    reconcileTransientState()
    defer { onSessionChanged?() }
    if let managedSave {
      let result = managedSave(session, deferred)
      session = result.session
      storageNotice = result.notice
      reconcileTransientState()
      return
    }
    guard maySave, let sessionFile else { return }
    let snapshot = session
    snapshotScheduler.schedule(
      deferred: deferred, { try sessionFile.save(snapshot) },
      completion: { [weak self] failure in
        self?.storageNotice = Self.saveNotice(failure: failure)
      })
  }

  /// Waits until the latest change is on disk. Ordinary saves return before the disk flush.
  func flushSaves() throws {
    do {
      try snapshotScheduler.flush()
    } catch {
      storageNotice = Self.saveNotice(failure: error.localizedDescription)
      throw error
    }
  }

  private static func saveNotice(failure: String?) -> String? {
    failure.map { ShellL10n.format("Changes could not be saved. %@", arguments: [.string($0)]) }
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

  static func preview(showCommand: Bool) -> BrowserStore {
    var session = BrowserSession.fresh()
    for address in ["https://github.com", "https://linear.app", "https://developer.apple.com"] {
      if let url = URL(string: address), let id = session.open(url) { session.togglePin(id) }
    }
    if let url = URL(string: "https://github.com/arcusis/shaar") { session.open(url) }
    let store = BrowserStore(session: session)
    store.commandIsOpen = showCommand
    return store
  }
}

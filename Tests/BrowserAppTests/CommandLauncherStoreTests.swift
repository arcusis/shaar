import Foundation
import Testing

@testable import ArcusisBrowser
@testable import BrowserCore

@Suite @MainActor
struct CommandLauncherStoreTests {
  @Test func actionsAppearOnlyWhenAHostCanRunThem() {
    let store = BrowserStore()
    store.showCommand()
    store.commandFilter = .actions
    #expect(store.results.isEmpty)

    store.launcherActions = LauncherActions(available: { LauncherCommands.catalog }, run: { _ in })
    #expect(store.results.map(\.action).contains(.command(BrowserMenuCommand.splitView.rawValue)))
  }

  @Test func actionsListOnlyWhatTheHostEnablesUnderItsCurrentTitle() {
    let store = BrowserStore()
    let closeTab = LauncherCommand(
      id: BrowserMenuCommand.closeTab.rawValue, title: "Close tab", detail: "Tabs", symbol: "x")
    let reopen = LauncherCommand(
      id: BrowserMenuCommand.reopenClosed.rawValue, title: "Reopen last closed tab",
      detail: "Tabs", symbol: "arrow.uturn.backward")
    var available = [closeTab]
    store.launcherActions = LauncherActions(available: { available }, run: { _ in })
    store.showCommand()
    store.commandFilter = .actions
    #expect(store.results.map(\.title) == ["Close tab"])

    available = [closeTab.retitled("Close window"), reopen]
    #expect(store.results.map(\.title) == ["Close window", "Reopen last closed tab"])

    available = []
    #expect(store.results.isEmpty)
  }

  @Test func runningAnActionClosesTheLauncherBeforeTheHostCommand() {
    let store = BrowserStore()
    var ran: [(String, Bool)] = []
    store.launcherActions = LauncherActions(
      available: { LauncherCommands.catalog }, run: { ran.append(($0, store.commandIsOpen)) })
    store.showCommand()

    store.perform(.command(BrowserMenuCommand.newSpace.rawValue))

    #expect(ran.map(\.0) == [BrowserMenuCommand.newSpace.rawValue])
    #expect(ran.map(\.1) == [false])
    #expect(!store.commandIsOpen)
  }

  @Test func plainWordsWithNoHitsStillSearchTheWebOnEnter() throws {
    let store = BrowserStore()
    store.launcherActions = LauncherActions(available: { LauncherCommands.catalog }, run: { _ in })
    store.showCommand()
    store.commandQuery = "history"

    #expect(store.selectedCommandResult?.isOpen == true)
    #expect(store.results.map(\.action).contains(.command(BrowserMenuCommand.history.rawValue)))
    store.acceptCommand()
    let url = try #require(store.session.selectedPage?.tab.url)
    #expect(url.host() == "www.google.com")
  }

  @Test func catalogReusesMenuTitlesAndShortcutsWithoutLauncherCommands() throws {
    let ids = LauncherCommands.catalog.map(\.id)
    for included in [BrowserMenuCommand.newSpace, .settings, .splitView, .sidebar] {
      #expect(ids.contains(included.rawValue))
    }
    for excluded in [BrowserMenuCommand.newTab, .search, .quit, .closeWindow] {
      #expect(!ids.contains(excluded.rawValue))
    }
    let split = try #require(
      LauncherCommands.catalog.first { $0.id == BrowserMenuCommand.splitView.rawValue })
    #expect(split.title == "Split View")
    #expect(split.detail == "Tabs · ⌃⇧=")
    #expect(LauncherCommands.catalog.allSatisfy { !$0.title.hasSuffix("…") })
  }

  @Test func filterChangesResetSelectionAndReopeningClearsTheFilter() {
    let store = BrowserStore()
    for index in 0..<3 {
      store.perform(.open(URL(string: "https://filter-\(index).example")!))
    }
    store.showCommand()
    store.moveCommandSelection(by: 2)
    #expect(store.commandSelection == 2)

    store.cycleCommandFilter(by: 1)
    #expect(store.commandFilter == .tabs)
    #expect(store.commandSelection == 0)
    store.cycleCommandFilter(by: -1)
    #expect(store.commandFilter == nil)

    store.commandFilter = .history
    store.dismissCommand()
    store.showCommand()
    #expect(store.commandFilter == nil)
  }

  @Test func selectionKeepsItsRowWhenResultsChangeAndClampsWhenItIsGone() throws {
    let store = BrowserStore()
    let ids = try (0..<3).map {
      let opened = store.session.open(URL(string: "https://row-\($0).example")!)
      return try #require(opened)
    }
    store.showCommand()
    let target = CommandAction.tab(space: store.session.selectedSpaceID, tab: ids[2])
    let targetIndex = try #require(store.results.firstIndex { $0.action == target })
    store.moveCommandSelection(by: targetIndex)
    #expect(store.selectedCommandResult?.action == target)

    store.session.closeTab(ids[0])
    #expect(store.selectedCommandResult?.action == target)
    #expect(store.commandSelection == targetIndex - 1)

    store.session.closeTab(ids[2])
    #expect(!store.results.contains { $0.action == target })
    #expect(store.commandSelection == min(targetIndex, store.results.count - 1))
  }

  @Test func keyboardSelectionSpansSuggestionSections() throws {
    let store = BrowserStore()
    let opened = store.session.open(URL(string: "https://pinned.example")!)
    let pinned = try #require(opened)
    store.session.togglePin(pinned)
    store.perform(.open(URL(string: "https://open.example")!))
    store.showCommand()
    let sections = store.commandSections
    #expect(sections.map(\.title) == ["Open Tabs", "Favorites & Pinned"])

    store.moveCommandSelection(by: 10)
    #expect(store.commandSelection == store.results.count - 1)
    #expect(
      store.results[store.commandSelection].action
        == .tab(space: store.session.selectedSpaceID, tab: pinned))
    store.acceptCommand()
    #expect(store.session.selectedPage?.tab.id == pinned)
    #expect(!store.commandIsOpen)
  }

  @Test func emptyStateCapsFavoritesAndPinnedTabsSeparately() throws {
    let store = BrowserStore()
    let profileID = store.session.selectedSpace.profileID
    for index in 0..<8 {
      let opened = store.session.open(URL(string: "https://pin-\(index).example")!)
      let id = try #require(opened)
      store.session.togglePin(id)
      store.session.addFavorite(
        profileID: profileID, originalURL: URL(string: "https://fav-\(index).example")!)
    }
    store.showCommand()

    let favorites = try #require(store.commandSections.first { $0.id == "favorites" })
    let kinds = favorites.results.map(\.symbol)
    #expect(kinds.count(where: { $0 == "star.fill" }) == CommandLauncher.suggestedFavoriteLimit)
    #expect(kinds.count(where: { $0 != "star.fill" }) == CommandLauncher.suggestedPinnedLimit)
  }

  @Test func tabsChipListsUpToTheFilteredLimitOfOpenAndClosedTabs() throws {
    let store = BrowserStore()
    var closing: [UUID] = []
    for index in 0..<(CommandLauncher.filteredLimit + 5) {
      let opened = store.session.open(URL(string: "https://chip-\(index).example")!)
      let id = try #require(opened)
      if index < 5 { closing.append(id) }
    }
    for id in closing { store.session.closeTab(id) }
    store.showCommand()
    store.commandFilter = .tabs

    let sections = store.commandSections
    #expect(sections.first { $0.id == "tabs" }?.results.count == CommandLauncher.filteredLimit)
    #expect(sections.first { $0.id == "recently-closed" }?.results.count == 5)
  }
}

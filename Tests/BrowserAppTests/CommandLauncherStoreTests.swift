import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct CommandLauncherStoreTests {
  @Test func actionsAppearOnlyWhenAHostCanRunThem() {
    let store = BrowserStore()
    store.showCommand()
    store.commandFilter = .actions
    #expect(store.results.isEmpty)

    store.onMenuCommand = { _ in }
    #expect(store.results.map(\.action).contains(.command(BrowserMenuCommand.splitView.rawValue)))
  }

  @Test func runningAnActionClosesTheLauncherBeforeTheHostCommand() {
    let store = BrowserStore()
    var ran: [(String, Bool)] = []
    store.onMenuCommand = { ran.append(($0, store.commandIsOpen)) }
    store.showCommand()

    store.perform(.command(BrowserMenuCommand.newSpace.rawValue))

    #expect(ran.map(\.0) == [BrowserMenuCommand.newSpace.rawValue])
    #expect(ran.map(\.1) == [false])
    #expect(!store.commandIsOpen)
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
}

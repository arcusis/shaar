// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore

/// The host side of launcher Actions, bound to the window that owns the launcher.
struct LauncherActions {
  /// Commands the owning window can run right now, with their current titles.
  let available: @MainActor () -> [LauncherCommand]
  let run: @MainActor (String) -> Void
}

/// Everything launcher sections are computed from; equal keys give equal sections.
struct CommandSectionsKey: Equatable {
  let query: String
  let filter: CommandFilter?
  let session: BrowserSession
  let sources: CommandSources
}

struct CommandSectionsCache {
  let key: CommandSectionsKey
  let sections: [CommandSection]
}

/// Menu commands the launcher lists as Actions, read from the same menu definitions the app
/// installs so titles and shortcuts stay in sync with the menu bar.
@MainActor
enum LauncherCommands {
  static let catalog: [LauncherCommand] = ShortcutCatalog.installed().entries
    .compactMap { command(for: $0) }

  /// The launcher itself, window chrome and repeat commands make no sense as Actions.
  private static let excluded: Set<BrowserMenuCommand> = [
    .newTab, .search, .closeWindow, .findNext, .findPrevious, .help, .minimizeWindow,
    .zoomWindow, .bringAllToFront, .quit,
  ]

  private static func command(for entry: ShortcutCatalog.Entry) -> LauncherCommand? {
    guard let name = entry.command, let command = BrowserMenuCommand(rawValue: name),
      !excluded.contains(command)
    else { return nil }
    let title = entry.title.trimmingCharacters(in: CharacterSet(charactersIn: "…"))
    let detail = entry.key.isEmpty ? entry.menu : "\(entry.menu) · \(entry.displayKeys)"
    return LauncherCommand(id: name, title: title, detail: detail, symbol: symbol(for: command))
  }

  private static func symbol(for command: BrowserMenuCommand) -> String {
    switch command {
    case .newWindow: "macwindow"
    case .newPrivateWindow: "eye.slash"
    case .newMiniWindow: "macwindow.badge.plus"
    case .newSpace: "plus.square.on.square"
    case .editSpace: "slider.horizontal.3"
    case .closeTab: "xmark.square"
    case .addFavorite: "star"
    case .reopenClosed: "arrow.uturn.backward"
    case .recentlyClosed: "clock.arrow.circlepath"
    case .bookmarkPage: "bookmark"
    case .bookmarks: "book"
    case .history: "clock"
    case .downloads: "arrow.down.circle"
    case .find: "magnifyingglass"
    case .sidebar: "sidebar.left"
    case .nextSpace: "arrow.right"
    case .previousSpace: "arrow.left"
    case .reload: "arrow.clockwise"
    case .splitView: "rectangle.split.2x1"
    case .extensions: "puzzlepiece.extension"
    case .settings: "gearshape"
    case .checkForUpdates: "arrow.triangle.2.circlepath"
    default: "command"
    }
  }
}

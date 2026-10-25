import AppKit
import BrowserCore
import SwiftUI

@main
enum ArcusisBrowserMain {
  @MainActor static func main() {
    let arguments = CommandLine.arguments
    if arguments.contains("--engine-probe") {
      exit(EngineProbe.run(arguments: arguments))
    }
    if let index = arguments.firstIndex(of: "--render-preview"),
      arguments.indices.contains(index + 1)
    {
      do {
        try renderPreview(
          to: URL(filePath: arguments[index + 1]), showCommand: arguments.contains("--command"),
          compact: arguments.contains("--compact"),
          hideSidebar: arguments.contains("--hide-sidebar"),
          showSpaceEditor: arguments.contains("--space-editor"),
          showExtensionConsent: arguments.contains("--extension-consent"))
      } catch {
        FileHandle.standardError.write(Data("Preview failed: \(error.localizedDescription)\n".utf8))
        exit(1)
      }
      return
    }
    if let frameworks = Bundle.main.privateFrameworksURL {
      let framework = frameworks.appending(path: "Chromium Framework.framework")
      if FileManager.default.fileExists(atPath: framework.path) {
        exit(NativeBrowserHost.run(frameworkURL: framework))
      }
    }
    BrowserApplication.main()
  }

  @MainActor private static func renderPreview(
    to url: URL, showCommand: Bool, compact: Bool, hideSidebar: Bool, showSpaceEditor: Bool,
    showExtensionConsent: Bool
  ) throws {
    // Render only this view hierarchy; never capture or activate the desktop.
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let size =
      showExtensionConsent
      ? NSSize(width: 516, height: 480)
      : showSpaceEditor
        ? NSSize(width: 496, height: 430)
        : compact ? NSSize(width: 760, height: 520) : NSSize(width: 1200, height: 780)
    let store = BrowserStore.preview(showCommand: showCommand)
    store.sidebarIsVisible = !hideSidebar
    let view = NativePreview(
      store: store, showSpaceEditor: showSpaceEditor,
      showExtensionConsent: showExtensionConsent
    )
    .frame(width: size.width, height: size.height)
    .background(Color(nsColor: .windowBackgroundColor))
    .environment(\.colorScheme, .light)
    let host = NSHostingView(rootView: view)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
      throw CocoaError(.fileWriteUnknown)
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: url, options: .atomic)
  }
}

private struct NativePreview: View {
  let store: BrowserStore
  let showSpaceEditor: Bool
  let showExtensionConsent: Bool

  var body: some View {
    if showExtensionConsent {
      ExtensionConsent(store: store, request: previewConsent)
    } else if showSpaceEditor {
      SpaceEditor(store: store, route: .create)
    } else {
      BrowserWindow(store: store)
    }
  }

  private var previewConsent: ExtensionInstallRequest {
    ExtensionInstallRequest(
      id: "preview", profileID: store.session.selectedSpace.profileID,
      tabID: store.session.selectedSpace.selectedTabID!,
      sourceURL: store.session.selectedSpace.selectedTab!.url,
      browserExtension: BrowserExtension(
        id: String(repeating: "a", count: 32),
        name: "Example Password Manager", version: "1.0")!,
      kind: .install,
      permissions: [
        "Read and change all your data on all websites", "Display notifications",
        "Read data you copy and paste",
      ])!
  }
}

private struct BrowserApplication: App {
  @State private var store = BrowserStore.preview(showCommand: false)

  var body: some Scene {
    Window("Arcusis Browser", id: "browser") {
      BrowserWindow(store: store)
    }
    .defaultSize(width: 1200, height: 780)
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("New tab") { store.showCommand() }.keyboardShortcut("t")
        Button("Search or enter address") { store.showCommand() }.keyboardShortcut("l")
        Button("New space…") { store.spaceEditor = .create }
        Button("Edit current space…") { store.spaceEditor = .edit(store.session.selectedSpaceID) }
        Button("Downloads") { store.showDownloads() }.keyboardShortcut(
          "j", modifiers: [.command, .shift])
      }
      CommandMenu("Tabs") {
        Button("Reload") { store.reloadCurrentPage() }.keyboardShortcut("r")
          .disabled(!store.canReloadCurrentPage)
        Button("Close tab") {
          if let id = store.session.selectedSpace.selectedTabID { store.closeTab(id) }
        }
        .keyboardShortcut("w")
        .disabled(store.session.selectedSpace.selectedTabID == nil)
        Button("Reopen last closed tab") { store.reopenLastClosedTab() }
          .keyboardShortcut("t", modifiers: [.command, .shift])
          .disabled(!store.canReopenClosedTab)
        Button("Recently closed…") { store.showRecentlyClosed() }.disabled(store.sheet != nil)
        Button("Toggle sidebar") { store.sidebarIsVisible.toggle() }.keyboardShortcut("s")
        Divider()
        Button("Next space") { store.cycleSpace(by: 1) }.keyboardShortcut(
          "]", modifiers: [.control, .option])
        Button("Previous space") { store.cycleSpace(by: -1) }.keyboardShortcut(
          "[", modifiers: [.control, .option])
      }
      CommandMenu("Bookmarks") {
        Button("Bookmark this page") { store.bookmarkCurrentPage() }.keyboardShortcut("d")
          .disabled(!store.canBookmarkCurrentPage)
        Button("Bookmarks…") { store.showLibrary(.bookmarks) }.disabled(store.sheet != nil)
        Button("History…") { store.showLibrary(.history) }.keyboardShortcut("y").disabled(
          store.sheet != nil)
      }
      CommandGroup(after: .textEditing) {
        Button("Find in Page…") { store.showPageFind() }.keyboardShortcut("f")
          .disabled(!store.canFindCurrentPage)
        Button("Find Next") { store.movePageFind(forward: true) }.keyboardShortcut("g")
          .disabled(store.pageFind?.canMove != true)
        Button("Find Previous") { store.movePageFind(forward: false) }
          .keyboardShortcut("g", modifiers: [.command, .shift])
          .disabled(store.pageFind?.canMove != true)
      }
    }
  }
}

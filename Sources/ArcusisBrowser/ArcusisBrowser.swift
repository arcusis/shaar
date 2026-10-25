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
          showExtensionConsent: arguments.contains("--extension-consent"),
          showRecentDownloads: arguments.contains("--recent-downloads"),
          showSettings: arguments.contains("--settings"),
          showSettingsProfiles: arguments.contains("--settings-profiles"),
          showSettingsProfileEditor: arguments.contains("--settings-profile-editor"))
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
    showExtensionConsent: Bool, showRecentDownloads: Bool, showSettings: Bool,
    showSettingsProfiles: Bool, showSettingsProfileEditor: Bool
  ) throws {
    if showSettings || showSettingsProfileEditor {
      try renderSettingsPreview(
        to: url, compact: compact, withProfiles: showSettingsProfiles,
        withProfileEditor: showSettingsProfileEditor)
      return
    }
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
      showExtensionConsent: showExtensionConsent, showRecentDownloads: showRecentDownloads
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

  @MainActor private static func renderSettingsPreview(
    to url: URL, compact: Bool, withProfiles: Bool, withProfileEditor: Bool
  ) throws {
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let dark = CommandLine.arguments.contains("--settings-dark")
    application.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let size =
      withProfileEditor
      ? NSSize(width: 440, height: 220)
      : compact ? NSSize(width: 620, height: 500) : NSSize(width: 720, height: 650)
    let view = Group {
      if withProfileEditor {
        ProfileNameEditor(
          title: "Rename Profile", initialName: "Work", onCancel: {}, onSave: { _ in true })
      } else {
        SettingsPreview(withProfiles: withProfiles)
      }
    }
    .frame(width: size.width, height: size.height)
    .background(Color(nsColor: .windowBackgroundColor))
    .environment(\.colorScheme, dark ? .dark : .light)
    try renderOffscreen(view, to: url, size: size)
  }

  @MainActor private static func renderOffscreen<V: View>(
    _ view: V, to url: URL, size: NSSize
  ) throws {
    let host = NSHostingView(rootView: view)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered,
      defer: false
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

private struct SettingsPreview: View {
  let withProfiles: Bool
  @State private var selectedProfileID: UUID?
  @State private var sidebarInitiallyVisible = true
  @State private var selectedSearchEngine = "google"

  private let profiles = [
    BrowserSettingsProfile(
      id: UUID(uuidString: "0A3126F1-683D-4F4F-9C48-7B7C6E741250")!, name: "Work", spaceCount: 3),
    BrowserSettingsProfile(
      id: UUID(uuidString: "C992DA8B-4547-4218-A2CE-4E22B2D4FE88")!, name: "Personal",
      spaceCount: 1),
    BrowserSettingsProfile(
      id: UUID(uuidString: "5FEA8AA6-47B6-4270-880C-FF565FFAC16D")!, name: "Research",
      spaceCount: 2),
  ]
  private let searchEngines = [
    BrowserSettingsChoice(id: "google", title: "Google"),
    BrowserSettingsChoice(id: "duckDuckGo", title: "DuckDuckGo"),
    BrowserSettingsChoice(id: "bing", title: "Bing"),
  ]

  var body: some View {
    BrowserSettingsView(
      profiles: withProfiles ? profiles : [], searchEngines: searchEngines,
      selectedProfileID: $selectedProfileID, sidebarInitiallyVisible: $sidebarInitiallyVisible,
      selectedSearchEngine: $selectedSearchEngine,
      initialSection: withProfiles ? .profiles : .general
    )
    .onAppear {
      selectedProfileID =
        withProfiles
        ? profiles.first?.id
        : UUID(
          uuidString: "E923A7C4-310F-4B2F-A174-0634C377850A")
    }
  }
}

private struct NativePreview: View {
  let store: BrowserStore
  let showSpaceEditor: Bool
  let showExtensionConsent: Bool
  let showRecentDownloads: Bool

  var body: some View {
    if showRecentDownloads {
      let profileID = store.session.selectedSpace.profileID
      HStack(spacing: 0) {
        BrowserSidebar(
          store: store, previewRecentDownloads: Self.previewDownloads(profileID: profileID)
        )
        .frame(width: BrowserChromeLayout.sidebarWidth)
        VStack {
          Text("Authored page preview").font(.headline).foregroundStyle(.secondary)
          Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(10)
      }
      .background(store.session.selectedSpace.themeColor.opacity(0.5))
    } else if showExtensionConsent {
      ExtensionConsent(store: store, request: previewConsent)
    } else if showSpaceEditor {
      SpaceEditor(store: store, route: .create)
    } else {
      BrowserWindow(store: store)
    }
  }

  private static func previewDownloads(profileID: UUID) -> [BrowserDownload] {
    [
      BrowserDownload(
        id: "8ce51349-a188-4bad-bd1c-011b48e48ca6", profileID: profileID,
        filename: "Arcusis-Release.dmg", path: "/preview/Arcusis-Release.dmg",
        sourceURL: "https://downloads.example.test/Arcusis-Release.dmg", state: .finished,
        paused: false, dangerous: false, offTheRecord: false,
        received: 98_304_000, total: 98_304_000, startTime: 3)!,
      BrowserDownload(
        id: "309f2448-0e6c-44a3-9db4-57b3f9ca4a0a", profileID: profileID,
        filename: "research-notes.pdf", path: "/preview/research-notes.pdf",
        sourceURL: "https://files.example.test/research-notes.pdf", state: .downloading,
        paused: false, dangerous: false, offTheRecord: false,
        received: 65_536, total: 262_144, startTime: 2)!,
      BrowserDownload(
        id: "588a94a2-2a2e-4762-9f35-3e4590356a09", profileID: profileID,
        filename: "image-export.zip", path: "/preview/image-export.zip",
        sourceURL: "https://files.example.test/image-export.zip", state: .downloading,
        paused: true, dangerous: false, offTheRecord: false,
        received: 1_048_576, total: -1, startTime: 1)!,
    ]
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

import AppKit
import SwiftUI

@main
enum ArcusisBrowserMain {
  @MainActor static func main() {
    let arguments = CommandLine.arguments
    if let index = arguments.firstIndex(of: "--render-preview"),
      arguments.indices.contains(index + 1)
    {
      do {
        try renderPreview(
          to: URL(filePath: arguments[index + 1]), showCommand: arguments.contains("--command"),
          compact: arguments.contains("--compact"))
      } catch {
        FileHandle.standardError.write(Data("Preview failed: \(error.localizedDescription)\n".utf8))
        exit(1)
      }
      return
    }
    BrowserApplication.main()
  }

  @MainActor private static func renderPreview(to url: URL, showCommand: Bool, compact: Bool) throws
  {
    // Render only this view hierarchy; never capture or activate the desktop.
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let size = compact ? NSSize(width: 760, height: 520) : NSSize(width: 1200, height: 780)
    let view = BrowserWindow(store: .preview(showCommand: showCommand))
      .frame(width: size.width, height: size.height)
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

private struct BrowserApplication: App {
  @State private var store = BrowserStore.persistent()

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
        Button("New space…") { store.newSpaceIsOpen = true }
      }
      CommandMenu("Tabs") {
        Button("Close tab") {
          if let id = store.session.selectedSpace.selectedTabID { store.closeTab(id) }
        }
        .keyboardShortcut("w")
        .disabled(store.session.selectedSpace.selectedTabID == nil)
        Button("Toggle sidebar") { store.sidebarIsVisible.toggle() }.keyboardShortcut("s")
        Divider()
        Button("Next space") { store.cycleSpace(by: 1) }.keyboardShortcut(
          "]", modifiers: [.control, .option])
        Button("Previous space") { store.cycleSpace(by: -1) }.keyboardShortcut(
          "[", modifiers: [.control, .option])
      }
    }
  }
}

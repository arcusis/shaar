import BrowserCore
import SwiftUI

struct MediaCaptureIndicator: View {
  let store: BrowserStore
  let engine: BrowserEngine

  var body: some View {
    if !capturingTabs.isEmpty {
      Menu {
        ForEach(capturingTabs) { tab in
          Button {
            store.perform(.tab(space: tab.spaceID, tab: tab.id))
          } label: {
            Text("\(tab.spaceName): \(tab.title) — \(tab.resources)")
          }
        }
      } label: {
        Label(
          "In use", systemImage: captureSymbol
        )
        .font(.caption.weight(.semibold)).foregroundStyle(.red)
      }
      .menuIndicator(.hidden)
      .help("Camera, microphone, or screen capture is active. Choose a tab to return to it.")
      .accessibilityLabel("Active capture in \(capturingTabs.count) tabs")
    }
  }

  private var captureSymbol: String {
    if capturingTabs.contains(where: { $0.camera }) { return "camera.fill" }
    if capturingTabs.contains(where: { $0.microphone }) { return "mic.fill" }
    return "display"
  }

  private var capturingTabs: [CapturingTab] {
    store.session.spaces.flatMap { space in
      space.tabs.compactMap { tab in
        guard let access = engine.mediaAccess[tab.id], access.isCapturing else { return nil }
        let resources = [
          access.camera ? "camera" : nil, access.microphone ? "microphone" : nil,
          access.screen ? "screen" : nil,
        ].compactMap { $0 }.joined(separator: ", ")
        return CapturingTab(
          id: tab.id, spaceID: space.id, spaceName: space.name,
          title: tab.title, resources: resources, camera: access.camera,
          microphone: access.microphone)
      }
    }
  }
}

private struct CapturingTab: Identifiable {
  let id: UUID
  let spaceID: UUID
  let spaceName: String
  let title: String
  let resources: String
  let camera: Bool
  let microphone: Bool
}

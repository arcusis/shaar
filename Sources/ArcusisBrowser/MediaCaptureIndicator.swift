// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
    let ordinary: [CapturingTab] = store.session.spaces.flatMap { space -> [CapturingTab] in
      space.tabs.compactMap { tab -> CapturingTab? in
        guard let access = engine.mediaAccess[tab.id], access.isCapturing else { return nil }
        return CapturingTab(
          id: tab.id, spaceID: space.id, spaceName: space.name,
          title: tab.title, resources: resources(for: access), camera: access.camera,
          microphone: access.microphone)
      }
    }
    let favorites: [CapturingTab] = store.session.favoritePages.compactMap {
      page -> CapturingTab? in
      guard let spaceID = store.spaceID(showingPage: page.tab.id),
        let space = store.session.spaces.first(where: { $0.id == spaceID }),
        let access = engine.mediaAccess[page.tab.id], access.isCapturing
      else { return nil }
      return CapturingTab(
        id: page.tab.id, spaceID: space.id, spaceName: space.name,
        title: page.tab.title, resources: resources(for: access), camera: access.camera,
        microphone: access.microphone)
    }
    return ordinary + favorites
  }

  private func resources(for access: MediaAccessState) -> String {
    [
      access.camera ? "camera" : nil, access.microphone ? "microphone" : nil,
      access.screen ? "screen" : nil,
    ]
    .compactMap { $0 }.joined(separator: ", ")
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

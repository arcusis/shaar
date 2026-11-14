// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct BrowserChromeControlCountPreferenceKey: PreferenceKey {
  static let defaultValue: [String: Int] = [:]

  static func reduce(value: inout [String: Int], nextValue: () -> [String: Int]) {
    for (identifier, count) in nextValue() {
      value[identifier, default: 0] += count
    }
  }
}

extension View {
  func browserChromeControl(_ identifier: String) -> some View {
    accessibilityIdentifier(identifier)
      .preference(key: BrowserChromeControlCountPreferenceKey.self, value: [identifier: 1])
  }
}

struct BrowserChromeAccessibilityOverrides {
  var reduceTransparency: Bool?
  var reduceMotion: Bool?

  func reduceMotionEnabled(systemSetting: Bool) -> Bool {
    systemSetting || reduceMotion == true
  }
}

private struct BrowserChromeAccessibilityOverridesKey: EnvironmentKey {
  static let defaultValue = BrowserChromeAccessibilityOverrides()
}

extension EnvironmentValues {
  var browserChromeAccessibilityOverrides: BrowserChromeAccessibilityOverrides {
    get { self[BrowserChromeAccessibilityOverridesKey.self] }
    set { self[BrowserChromeAccessibilityOverridesKey.self] = newValue }
  }
}

struct BrowserChromeSurface: View {
  @Bindable var store: BrowserStore
  let engine: BrowserEngine?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.browserChromeAccessibilityOverrides) private var accessibilityOverrides

  var body: some View {
    HStack(spacing: 4) {
      if !store.sidebarIsVisible {
        chromeButton("sidebar.leading", label: ShellL10n.string("Toggle sidebar")) {
          store.sidebarIsVisible.toggle()
        }
      }
      if store.selectedSplit == nil {
        PageNavigationButtons(store: store, engine: engine)
      }
      if store.isPrivate {
        Label(ShellL10n.string("Private browsing"), systemImage: "eye.slash.fill")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.purple)
          .accessibilityIdentifier("browser.private.marker")
      }
      if let split = store.selectedSplit {
        SplitLayoutControls(store: store, split: split)
      }
      WindowDragRegion()
        .frame(maxWidth: .infinity)
        .frame(height: 24)
      pageActions
    }
    .overlay {
      if store.selectedSplit == nil {
        PageAddressField(store: store)
          .frame(maxWidth: 520)
          .padding(.horizontal, 120)
      }
    }
    .padding(.horizontal, 6)
    .frame(height: 34)
    .background(SpaceChromeTint(space: store.session.selectedSpace).color(for: colorScheme))
    .animation(
      accessibilityOverrides.reduceMotionEnabled(systemSetting: reduceMotion)
        ? nil : .easeOut(duration: 0.18),
      value: SpaceChromeTint(space: store.session.selectedSpace)
    )
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private var pageActions: some View {
    if let engine {
      HStack(spacing: 4) {
        MediaCaptureIndicator(store: store, engine: engine)
          .fixedSize()
        DeveloperSimulationBadge(engine: engine)
        DevelopmentModeButton(engine: engine)
        SiteControlsButton(engine: engine, store: store)
        ExtensionToolbar(engine: engine, store: store)
          .frame(width: 28, height: 28)
      }
    } else if let page = store.privatePage {
      PrivateSiteControlsButton(store: store, runtime: page.runtime)
    }
  }

  private func chromeButton(
    _ symbol: String, label: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .medium))
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }
    .help(label)
    .accessibilityLabel(label)
  }
}

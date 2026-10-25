import SwiftUI

struct BrowserChromeAccessibilityOverrides {
  var reduceTransparency: Bool?
  var reduceMotion: Bool?
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
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.browserChromeAccessibilityOverrides) private var accessibilityOverrides

  var body: some View {
    GeometryReader { geometry in
      let addressWidth = BrowserChromeSurfaceLayout.addressWidth(in: geometry.size.width)

      HStack(spacing: 0) {
        leadingLane
          .frame(width: BrowserChromeSurfaceLayout.laneWidth, alignment: .leading)
        WindowDragRegion()
          .frame(maxWidth: .infinity)
          .frame(height: 24)
        addressControl
          .frame(width: addressWidth, height: 24)
        WindowDragRegion()
          .frame(maxWidth: .infinity)
          .frame(height: 24)
        trailingLane
          .frame(width: BrowserChromeSurfaceLayout.laneWidth, alignment: .trailing)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(height: 34)
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private var leadingLane: some View {
    if store.sidebarIsVisible {
      WindowDragRegion()
        .frame(maxWidth: .infinity)
        .frame(height: 24)
    } else {
      navigationControls
    }
  }

  @ViewBuilder
  private var trailingLane: some View {
    if engine == nil {
      WindowDragRegion()
        .frame(maxWidth: .infinity)
        .frame(height: 24)
    } else {
      pageActions
    }
  }

  private var navigationControls: some View {
    HStack(spacing: 4) {
      chromeButton("sidebar.left", label: "Toggle sidebar (Command-S)") {
        store.sidebarIsVisible.toggle()
      }

      if let engine, let id = store.session.selectedSpace.selectedTabID {
        let state = engine.pages[id]
        chromeButton("chevron.left", label: "Back") {
          engine.runtime.goBack(inTabID: id.uuidString)
        }
        .disabled(state?.canGoBack != true)

        chromeButton("chevron.right", label: "Forward") {
          engine.runtime.goForward(inTabID: id.uuidString)
        }
        .disabled(state?.canGoForward != true)

        chromeButton("arrow.clockwise", label: "Reload (Command-R)") {
          store.reloadCurrentPage()
        }
        .disabled(!store.canReloadCurrentPage)
      }
    }
  }

  private var addressControl: some View {
    let host = store.session.selectedSpace.selectedTab?.url.host()
    let title = host ?? "Search or enter address"
    let shouldReduceTransparency = accessibilityOverrides.reduceTransparency ?? reduceTransparency
    let shouldReduceMotion = accessibilityOverrides.reduceMotion ?? reduceMotion

    return Button {
      store.showCommand()
    } label: {
      HStack(spacing: 7) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 10, weight: .medium))
        Text(title)
          .font(.system(size: 12, weight: .medium))
          .lineLimit(1)
          .truncationMode(.middle)
          .contentTransition(.opacity)
      }
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background {
        if shouldReduceTransparency {
          Capsule().fill(Color(nsColor: .controlBackgroundColor))
            .overlay(Capsule().strokeBorder(.quaternary.opacity(0.75)))
        } else {
          Capsule()
            .fill(.clear)
            .glassEffect(.regular, in: Capsule())
        }
      }
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .help("Search or enter address (Command-L)")
    .accessibilityLabel(host.map { "Address: \($0)" } ?? "Search or enter address")
    .animation(shouldReduceMotion ? nil : .easeOut(duration: 0.14), value: title)
  }

  @ViewBuilder
  private var pageActions: some View {
    if let engine {
      HStack(spacing: 4) {
        MediaCaptureIndicator(store: store, engine: engine)
          .fixedSize()
        ExtensionToolbar(engine: engine, store: store)
          .frame(width: 28, height: 28)
      }
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

enum BrowserChromeSurfaceLayout {
  static let laneWidth: CGFloat = 123
  static let minimumDragGap: CGFloat = 12
  static let minimumAddressWidth: CGFloat = 80
  static let maximumAddressWidth: CGFloat = 236

  static func addressWidth(in availableWidth: CGFloat) -> CGFloat {
    min(
      maximumAddressWidth,
      max(
        minimumAddressWidth,
        availableWidth - laneWidth * 2 - minimumDragGap * 2
      )
    )
  }

  static func dragGapWidth(in availableWidth: CGFloat) -> CGFloat {
    (availableWidth - laneWidth * 2 - addressWidth(in: availableWidth)) / 2
  }
}

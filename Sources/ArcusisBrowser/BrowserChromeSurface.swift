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
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.browserChromeAccessibilityOverrides) private var accessibilityOverrides

  var body: some View {
    HStack(spacing: 4) {
      if !store.sidebarIsVisible {
        chromeButton("sidebar.left", label: "Toggle sidebar (Command-S)") {
          store.sidebarIsVisible.toggle()
        }
      }
      PageNavigationButtons(store: store, engine: engine)
      WindowDragRegion()
        .frame(maxWidth: .infinity)
        .frame(height: 24)
      pageActions
    }
    .overlay {
      PageAddressField(store: store)
        .frame(maxWidth: 520)
        .padding(.horizontal, 120)
    }
    .padding(.horizontal, 6)
    .frame(height: 34)
    .background(SpaceChromeTint(space: store.session.selectedSpace).color(for: colorScheme))
    .animation(
      (accessibilityOverrides.reduceMotion ?? reduceMotion) ? nil : .easeOut(duration: 0.18),
      value: SpaceChromeTint(space: store.session.selectedSpace)
    )
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private var pageActions: some View {
    if let engine {
      HStack(spacing: 4) {
        if engine.passwordFillAvailable, let coordinator = engine.passwordFill {
          PasswordFillAction(coordinator: coordinator)
        }
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

private struct PasswordFillAction: View {
  @Bindable var coordinator: NativePasswordFillCoordinator

  var body: some View {
    Button {
      coordinator.request()
    } label: {
      Image(systemName: "key.fill")
        .font(.system(size: 13, weight: .medium))
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }
    .help("Fill password")
    .accessibilityLabel("Fill password")
  }
}

struct PasswordFillPicker: View {
  @Bindable var coordinator: NativePasswordFillCoordinator

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let message = coordinator.message {
        Text(message)
      } else {
        Text("Choose a vault entry").font(.headline)
        Text("Entries may not match this form and can be refused.").font(.caption)
        if coordinator.entries.isEmpty { Text("No logins available.") }
        ScrollView {
          LazyVStack(alignment: .leading) {
            ForEach(coordinator.entries) { entry in
              Button {
                coordinator.choose(entry.id)
              } label: {
                VStack(alignment: .leading) {
                  Text(entry.name)
                  if let username = entry.username {
                    Text(username).font(.caption).foregroundStyle(.secondary)
                  }
                }.frame(maxWidth: .infinity, alignment: .leading)
              }.disabled(coordinator.busy)
            }
          }
        }.frame(maxHeight: 240)
      }
      Button("Cancel") { coordinator.cancel() }.keyboardShortcut(.cancelAction)
    }
    .padding(12)
    .frame(width: 280)
    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    .shadow(radius: 12)
  }
}

/// Same-window presentation used by the browser and guarded component captures.
struct PasswordFillOverlay: View {
  @Bindable var coordinator: NativePasswordFillCoordinator

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Color.clear.contentShape(Rectangle()).onTapGesture { coordinator.cancel() }
      PasswordFillPicker(coordinator: coordinator)
        .padding(.top, 46)
        .padding(.trailing, 20)
    }
  }
}

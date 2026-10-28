import AppKit
import BrowserCore
import SwiftUI

struct SplitPageView<Pane: View>: View {
  let split: BrowserSplit
  let focusedID: UUID?
  let onFocus: (UUID) -> Void
  let onUnsplit: (UUID) -> Void
  let onRatioChange: (Double) -> Void
  @ViewBuilder let pane: (UUID) -> Pane
  @State private var dragStart: Double?

  var body: some View {
    GeometryReader { geometry in
      let width = max(0, geometry.size.width - 6)
      let minimum = min(240, width / 2)
      let left = min(max(width * split.ratio, minimum), width - minimum)
      HStack(spacing: 0) {
        paneView(split.tabIDs[0]).frame(width: left)
        Rectangle()
          .fill(Color.secondary.opacity(0.25))
          .frame(width: 6)
          .contentShape(Rectangle())
          .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
              let start = dragStart ?? split.ratio
              if dragStart == nil { dragStart = start }
              guard width > 0 else { return }
              let next = min(max(width * start + value.translation.width, minimum), width - minimum)
              onRatioChange(next / width)
            }
            .onEnded { _ in dragStart = nil })
          .accessibilityLabel("Split divider")
        paneView(split.tabIDs[1]).frame(width: max(0, width - left))
      }
    }
  }

  private func paneView(_ id: UUID) -> some View {
    pane(id)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background { SplitPaneFocusObserver(onFocus: { onFocus(id) }) }
      .contentShape(Rectangle())
      .simultaneousGesture(TapGesture().onEnded { onFocus(id) })
      .overlay {
        Rectangle().strokeBorder(id == focusedID ? Color.accentColor : .clear, lineWidth: 2)
          .allowsHitTesting(false)
      }
      .overlay(alignment: .topTrailing) {
        Button { onUnsplit(id) } label: {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .semibold))
            .padding(6)
            .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(6)
        .help("Remove pane from split")
      }
  }
}

struct BrowserSplitPageView: View {
  let store: BrowserStore
  let engine: BrowserEngine
  let split: BrowserSplit

  var body: some View {
    SplitPageView(
      split: split, focusedID: store.session.selectedSpace.selectedTabID,
      onFocus: { store.focusSplitTab($0) }, onUnsplit: { store.unsplitTab($0) },
      onRatioChange: { store.setSplitRatio($0, splitID: split.id) }
    ) { id in
      if let failure = store.rendererFailures[id] {
        FailedPageView(store: store, failure: failure)
      } else if engine.pages[id] != nil {
        ChromiumPage(engine: engine, tabID: id, autofocus: id == store.session.selectedSpace.selectedTabID)
      } else {
        ProgressView("Loading profile…")
      }
    }
  }
}

private struct SplitPaneFocusObserver: NSViewRepresentable {
  let onFocus: () -> Void

  func makeNSView(context: Context) -> SplitPaneFocusView {
    let view = SplitPaneFocusView()
    view.onFocus = onFocus
    return view
  }

  func updateNSView(_ view: SplitPaneFocusView, context: Context) {
    view.onFocus = onFocus
  }
}

private final class SplitPaneFocusView: NSView {
  var onFocus: (() -> Void)?
  private var monitor: Any?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    guard window != nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
      guard let self, event.window === self.window,
        self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
      self.onFocus?()
      return event
    }
  }

  isolated deinit {
    if let monitor { NSEvent.removeMonitor(monitor) }
  }
}

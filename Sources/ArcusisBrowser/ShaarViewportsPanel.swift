// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI

struct ShaarViewportsPanel: View {
  @Bindable var model: ShaarViewportsModel
  @State private var address = ""
  @State private var typedText = ""
  @State private var errorMessage: String?

  var body: some View {
    VStack(spacing: 0) {
      controls
      syncControls
      Divider()
      if model.frames.isEmpty {
        emptyState
      } else {
        GeometryReader { proxy in
          let scale = previewScale(in: proxy.size)
          ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: ShaarViewportPreviewLayout.cardSpacing) {
              ForEach(model.frames) { frame in
                viewportCard(frame, scale: scale)
              }
            }
            .padding(14)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.025))
      }
      if let errorMessage {
        Text(errorMessage)
          .font(.system(size: 10))
          .foregroundStyle(.primary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 14)
          .frame(height: 25)
      }
    }
    .onAppear {
      address = model.frames.first?.url.absoluteString ?? model.target.url.absoluteString
    }
    .onChange(of: model.frames.first?.url) { _, url in
      if let url { address = url.absoluteString }
    }
    .accessibilityIdentifier("shaar.devtools.viewports.panel")
  }

  private var controls: some View {
    HStack(spacing: 9) {
      Text(ShellL10n.string("Synced viewports"))
        .font(.system(size: 10, weight: .semibold))
      TextField(ShellL10n.string("Page URL"), text: $address)
        .textFieldStyle(.roundedBorder)
        .devToolsDataDirection()
        .font(.system(size: 10, design: .monospaced))
        .frame(maxWidth: 380)
        .onSubmit(navigate)
        .accessibilityIdentifier("shaar.devtools.viewports.address")
      Button(ShellL10n.string("Go"), action: navigate)
        .controlSize(.small)
      Spacer(minLength: 8)
      Text(ShellL10n.plural("%d viewports", count: model.frames.count))
        .font(.system(size: 10)).foregroundStyle(.primary)
      Button(ShellL10n.string("Fit")) { model.zoomToFit.toggle() }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(model.zoomToFit ? Color.accentColor : Color.secondary)
        .accessibilityIdentifier("shaar.devtools.viewports.fit")
        .accessibilityAddTraits(model.zoomToFit ? [.isSelected] : [])
      Menu {
        ForEach(ShaarViewportPreset.allCases, id: \.self) { preset in
          Button(ShellL10n.string(preset.title)) { run(.add(preset)) }
        }
      } label: {
        Label(ShellL10n.string("Add viewport"), systemImage: "plus")
          .font(.system(size: 10))
      }
      .menuStyle(.borderlessButton)
      .frame(width: 115)
      .disabled(model.frames.count >= 4)
    }
    .padding(.horizontal, 14).frame(height: 36)
  }

  private var syncControls: some View {
    HStack(spacing: 9) {
      if model.capabilities.colorScheme {
        Menu {
          ForEach(ShaarViewportColorScheme.allCases, id: \.self) { scheme in
            Button(ShellL10n.string(scheme.title)) { run(.mirrorColorScheme(scheme)) }
          }
        } label: {
          Text(ShellL10n.string("Match color scheme"))
            .font(.system(size: 10))
        }
        .menuStyle(.borderlessButton)
        .frame(width: 140)
        .accessibilityIdentifier("shaar.devtools.viewports.colorScheme")
      }
      if model.capabilities.typing {
        TextField(ShellL10n.string("Type in all views"), text: $typedText)
          .textFieldStyle(.roundedBorder)
          .devToolsDataDirection()
          .font(.system(size: 10))
          .frame(maxWidth: 220)
          .onSubmit(typeInAllViews)
          .accessibilityIdentifier("shaar.devtools.viewports.type")
      }
      Spacer(minLength: 8)
      Button(ShellL10n.string("Screenshot all"), action: copyScreenshots)
        .controlSize(.small)
        .disabled(!model.frames.contains { !$0.pngData.isEmpty })
        .accessibilityIdentifier("shaar.devtools.viewports.screenshotAll")
    }
    .padding(.horizontal, 14)
    .frame(height: 32)
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: "rectangle.split.3x1")
        .font(.system(size: 23, weight: .ultraLight))
        .foregroundStyle(.primary)
      Text(ShellL10n.string("Add a device to preview this page"))
        .font(.system(size: 12)).foregroundStyle(.primary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func previewScale(in available: CGSize) -> CGFloat {
    let content = model.frames.map { frame in
      CGSize(width: frame.contentWidth, height: frame.contentHeight)
    }
    return ShaarViewportPreviewLayout.scale(
      fitting: model.zoomToFit, content: content, available: available)
  }

  private func viewportCard(_ frame: ShaarViewportFrame, scale: CGFloat) -> some View {
    let preview = ShaarViewportPreviewLayout.previewSize(
      contentWidth: frame.contentWidth, contentHeight: frame.contentHeight, scale: scale)
    let cardWidth = ShaarViewportPreviewLayout.cardWidth(previewWidth: preview.width)
    return VStack(spacing: 0) {
      cardHeader(frame)
      Divider()
      previewBody(frame, preview: preview, cardWidth: cardWidth)
      Divider()
      cardFooter(frame)
    }
    .frame(width: cardWidth)
    .background(Color(nsColor: .windowBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 7))
    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12)))
    .accessibilityIdentifier("shaar.devtools.viewports.\(frame.preset.rawValue)")
  }

  private func cardHeader(_ frame: ShaarViewportFrame) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: 6) {
        Text(ShellL10n.string(frame.preset.title))
          .font(.system(size: 11, weight: .semibold))
          .lineLimit(1)
        Spacer(minLength: 3)
        if model.capabilities.colorScheme {
          schemeButton(frame)
        }
        rotateButton(frame)
        removeButton(frame)
      }
      Text(sizeLabel(frame))
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.primary)
        .lineLimit(1)
    }
    .padding(.horizontal, 9)
    .frame(height: 44, alignment: .center)
  }

  private func sizeLabel(_ frame: ShaarViewportFrame) -> String {
    "\(frame.contentWidth) × \(frame.contentHeight) · \(ShellL10n.string(frame.colorScheme.title))"
  }

  private func schemeButton(_ frame: ShaarViewportFrame) -> some View {
    Button {
      run(.setColorScheme(frame.id, frame.colorScheme.next))
    } label: {
      Image(systemName: schemeSymbol(frame.colorScheme))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      ShellL10n.format(
        "%@ color scheme", arguments: [.string(ShellL10n.string(frame.preset.title))])
    )
    .accessibilityIdentifier("shaar.devtools.viewports.scheme.\(frame.preset.rawValue)")
  }

  private func schemeSymbol(_ scheme: ShaarViewportColorScheme) -> String {
    switch scheme {
    case .noPreference: "circle.lefthalf.filled"
    case .light: "sun.max"
    case .dark: "moon"
    }
  }

  private func rotateButton(_ frame: ShaarViewportFrame) -> some View {
    Button {
      run(.rotate(frame.id))
    } label: {
      Image(systemName: "rotate.right")
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      ShellL10n.format(
        "Rotate %@ viewport", arguments: [.string(ShellL10n.string(frame.preset.title))])
    )
  }

  private func removeButton(_ frame: ShaarViewportFrame) -> some View {
    Button {
      run(.remove(frame.id))
    } label: {
      Image(systemName: "xmark")
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      ShellL10n.format(
        "Remove %@ viewport", arguments: [.string(ShellL10n.string(frame.preset.title))])
    )
    .disabled(model.frames.count == 1)
  }

  private func previewBody(
    _ frame: ShaarViewportFrame, preview: CGSize, cardWidth: CGFloat
  ) -> some View {
    ZStack(alignment: .top) {
      if let image = NSImage(data: frame.pngData) {
        Image(nsImage: image)
          .resizable()
          .frame(width: preview.width, height: preview.height)
      } else {
        Color(nsColor: .textBackgroundColor)
          .frame(width: preview.width, height: preview.height)
        Text(ShellL10n.string("Waiting for page frame"))
          .font(.system(size: 11)).foregroundStyle(.primary)
      }
      ViewportInputSurface(
        width: frame.contentWidth, height: frame.contentHeight,
        onClick: { x, y in run(.click(frame.id, x: x, y: y)) },
        onScroll: { dx, dy in run(.scroll(frame.id, deltaX: dx, deltaY: dy)) },
        onHover: model.capabilities.hover
          ? { x, y in run(.hover(frame.id, x: x, y: y)) } : nil
      )
      .frame(width: preview.width, height: preview.height)
      if showsNotch(frame) {
        let notch = ShaarViewportPreviewLayout.notchSize(previewWidth: preview.width)
        Capsule().fill(Color.primary)
          .frame(width: notch.width, height: notch.height)
          .padding(.top, max(2, preview.width * 0.036))
          .allowsHitTesting(false)
      }
    }
    .frame(width: cardWidth, height: preview.height)
  }

  private func cardFooter(_ frame: ShaarViewportFrame) -> some View {
    HStack {
      SafeAreaEditor(frame: frame) { insets in
        run(.setSafeArea(frame.id, insets))
      }
      Spacer()
      Text(insetSummary(frame.safeArea))
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    .padding(.horizontal, 9).frame(height: 30)
  }

  private func insetSummary(_ insets: ShaarViewportInsets) -> String {
    "T \(insets.top) · R \(insets.right) · B \(insets.bottom) · L \(insets.left)"
  }

  private func showsNotch(_ frame: ShaarViewportFrame) -> Bool {
    frame.preset == .iphone15Pro && frame.orientation == .portrait && frame.safeArea.top > 0
  }

  private func navigate() {
    guard let url = URL(string: address) else {
      errorMessage = ShellL10n.string("Invalid page URL")
      return
    }
    run(.navigate(url))
  }

  private func typeInAllViews() {
    guard let frame = model.frames.first else { return }
    let text = typedText
    typedText = ""
    run(.type(frame.id, text: text))
  }

  private func copyScreenshots() {
    guard let png = model.contactSheetPNG() else {
      errorMessage = ShellL10n.string("Viewport screenshots are not ready")
      return
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setData(png, forType: .png)
    errorMessage = ShellL10n.string("Copied viewport screenshots")
  }

  private func run(_ action: ShaarViewportAction) {
    errorMessage = nil
    Task {
      do { try await model.perform(action) } catch { errorMessage = error.localizedDescription }
    }
  }
}

private struct SafeAreaEditor: View {
  let frame: ShaarViewportFrame
  let apply: (ShaarViewportInsets) -> Void
  @State private var top = 0
  @State private var right = 0
  @State private var bottom = 0
  @State private var left = 0

  var body: some View {
    Button(ShellL10n.string("Safe area…")) { syncDraft() }
      .font(.system(size: 10))
      .buttonStyle(.plain)
      .foregroundStyle(.primary)
      .popover(isPresented: $editing) {
        VStack(alignment: .leading, spacing: 8) {
          Text(ShellL10n.string("Safe area insets"))
            .font(.system(size: 12, weight: .semibold))
          insetRow("Top", value: $top)
          insetRow("Right", value: $right)
          insetRow("Bottom", value: $bottom)
          insetRow("Left", value: $left)
          HStack {
            Button(ShellL10n.string("Reset")) {
              apply(.zero)
              editing = false
            }
            Spacer()
            Button(ShellL10n.string("Apply")) {
              apply(ShaarViewportInsets(top: top, right: right, bottom: bottom, left: left))
              editing = false
            }
          }
        }
        .padding(12).frame(width: 210)
      }
  }

  @State private var editing = false

  private func insetRow(_ title: String, value: Binding<Int>) -> some View {
    Stepper(value: value, in: 0...200) {
      HStack {
        Text(ShellL10n.string(title))
        Spacer()
        Text("\(value.wrappedValue) px").monospacedDigit()
      }
      .font(.system(size: 11))
    }
  }

  private func syncDraft() {
    top = frame.safeArea.top
    right = frame.safeArea.right
    bottom = frame.safeArea.bottom
    left = frame.safeArea.left
    editing = true
  }
}

private struct ViewportInputSurface: NSViewRepresentable {
  let width: Int
  let height: Int
  let onClick: (Int, Int) -> Void
  let onScroll: (Int, Int) -> Void
  var onHover: ((Int, Int) -> Void)?

  func makeNSView(context: Context) -> InputView {
    InputView()
  }

  func updateNSView(_ view: InputView, context: Context) {
    view.viewportWidth = width
    view.viewportHeight = height
    view.onClick = onClick
    view.onScroll = onScroll
    view.onHover = onHover
  }

  final class InputView: NSView {
    var viewportWidth = 1
    var viewportHeight = 1
    var onClick: ((Int, Int) -> Void)?
    var onScroll: ((Int, Int) -> Void)?
    var onHover: ((Int, Int) -> Void)?
    private var tracking: NSTrackingArea?
    private var lastHover: (Int, Int)?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let tracking { removeTrackingArea(tracking) }
      let area = NSTrackingArea(
        rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
      addTrackingArea(area)
      tracking = area
    }

    override func mouseDown(with event: NSEvent) {
      guard let point = viewportPoint(event) else { return }
      onClick?(point.0, point.1)
    }

    override func mouseMoved(with event: NSEvent) {
      guard let onHover, let point = viewportPoint(event) else { return }
      if let lastHover, lastHover == point { return }
      self.lastHover = point
      onHover(point.0, point.1)
    }

    override func scrollWheel(with event: NSEvent) {
      let dx = Int(event.scrollingDeltaX.rounded())
      let dy = Int(event.scrollingDeltaY.rounded())
      onScroll?(max(-2_000, min(2_000, dx)), max(-2_000, min(2_000, dy)))
    }

    private func viewportPoint(_ event: NSEvent) -> (Int, Int)? {
      guard bounds.width > 0, bounds.height > 0, viewportWidth > 0, viewportHeight > 0 else {
        return nil
      }
      let point = convert(event.locationInWindow, from: nil)
      let x = min(viewportWidth - 1, max(0, Int(point.x / bounds.width * CGFloat(viewportWidth))))
      let y = min(
        viewportHeight - 1, max(0, Int(point.y / bounds.height * CGFloat(viewportHeight))))
      return (x, y)
    }
  }
}

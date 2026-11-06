// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI

struct ShaarViewportsPanel: View {
  @Bindable var model: ShaarViewportsModel
  @State private var address = ""
  @State private var errorMessage: String?

  var body: some View {
    VStack(spacing: 0) {
      controls
      Divider()
      if model.frames.isEmpty {
        emptyState
      } else {
        ScrollView([.horizontal, .vertical]) {
          HStack(alignment: .top, spacing: 12) {
            ForEach(model.frames) { frame in
              viewportCard(frame)
            }
          }
          .padding(14)
        }
        .background(Color.primary.opacity(0.025))
      }
      if let errorMessage {
        Text(errorMessage)
          .font(.system(size: 10))
          .foregroundStyle(.red)
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
        .font(.system(size: 10, design: .monospaced))
        .frame(maxWidth: 380)
        .onSubmit(navigate)
        .accessibilityIdentifier("shaar.devtools.viewports.address")
      Button(ShellL10n.string("Go"), action: navigate)
        .controlSize(.small)
      Spacer(minLength: 8)
      Text(ShellL10n.plural("%d viewports", count: model.frames.count))
        .font(.system(size: 10)).foregroundStyle(.secondary)
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

  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: "rectangle.split.3x1")
        .font(.system(size: 23, weight: .ultraLight))
        .foregroundStyle(.tertiary)
      Text(ShellL10n.string("Add a device to preview this page"))
        .font(.system(size: 12)).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func viewportCard(_ frame: ShaarViewportFrame) -> some View {
    let previewWidth = min(400, max(190, CGFloat(frame.preset.width) * 0.48))
    let previewHeight = previewWidth * CGFloat(frame.preset.height) / CGFloat(frame.preset.width)
    return VStack(spacing: 0) {
      HStack(spacing: 6) {
        Text(ShellL10n.string(frame.preset.title))
          .font(.system(size: 11, weight: .semibold))
        Spacer(minLength: 3)
        Text("\(frame.preset.width) × \(frame.preset.height)")
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(.secondary)
        Button {
          run(.remove(frame.id))
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.plain)
        .disabled(model.frames.count == 1)
        .accessibilityLabel(ShellL10n.string("Remove viewport"))
      }
      .padding(.horizontal, 9).frame(height: 30)
      Divider()
      ZStack(alignment: .top) {
        if let image = NSImage(data: frame.pngData) {
          Image(nsImage: image)
            .resizable()
            .frame(width: previewWidth, height: previewHeight)
        } else {
          Color(nsColor: .textBackgroundColor)
          Text(ShellL10n.string("Waiting for page frame"))
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        ViewportInputSurface(
          width: frame.preset.width, height: frame.preset.height,
          onClick: { x, y in run(.click(frame.id, x: x, y: y)) },
          onScroll: { dx, dy in run(.scroll(frame.id, deltaX: dx, deltaY: dy)) })
        if frame.preset == .iphone15Pro && frame.safeArea.top > 0 {
          Capsule().fill(Color.primary).frame(width: 49, height: 10).padding(.top, 7)
            .allowsHitTesting(false)
        }
      }
      .frame(width: previewWidth, height: previewHeight)
      Divider()
      HStack {
        SafeAreaEditor(frame: frame) { insets in
          run(.setSafeArea(frame.id, insets))
        }
        Spacer()
        Text("T \(frame.safeArea.top) · B \(frame.safeArea.bottom)")
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 9).frame(height: 30)
    }
    .frame(width: previewWidth)
    .background(Color(nsColor: .windowBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 7))
    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12)))
    .accessibilityIdentifier("shaar.devtools.viewports.\(frame.preset.rawValue)")
  }

  private func navigate() {
    guard let url = URL(string: address) else {
      errorMessage = ShellL10n.string("Invalid page URL")
      return
    }
    run(.navigate(url))
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
      .foregroundStyle(Color.accentColor)
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

  func makeNSView(context: Context) -> InputView {
    InputView()
  }

  func updateNSView(_ view: InputView, context: Context) {
    view.viewportWidth = width
    view.viewportHeight = height
    view.onClick = onClick
    view.onScroll = onScroll
  }

  final class InputView: NSView {
    var viewportWidth = 1
    var viewportHeight = 1
    var onClick: ((Int, Int) -> Void)?
    var onScroll: ((Int, Int) -> Void)?

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
      guard bounds.width > 0, bounds.height > 0 else { return }
      let point = convert(event.locationInWindow, from: nil)
      let x = min(viewportWidth - 1, max(0, Int(point.x / bounds.width * CGFloat(viewportWidth))))
      let y = min(
        viewportHeight - 1, max(0, Int(point.y / bounds.height * CGFloat(viewportHeight))))
      onClick?(x, y)
    }

    override func scrollWheel(with event: NSEvent) {
      let dx = Int(event.scrollingDeltaX.rounded())
      let dy = Int(event.scrollingDeltaY.rounded())
      onScroll?(max(-2_000, min(2_000, dx)), max(-2_000, min(2_000, dy)))
    }
  }
}

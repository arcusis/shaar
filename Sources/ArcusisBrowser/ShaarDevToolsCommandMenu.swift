// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI

struct ShaarDevToolsCommandMenu: View {
  @Bindable var model: ShaarDevToolsModel
  @FocusState private var focused: Bool

  var body: some View {
    let matches = model.commandMatches
    VStack(alignment: .leading, spacing: 0) {
      field
      Divider()
      results(matches)
    }
    .frame(maxWidth: 460)
    .background(Color(nsColor: .windowBackgroundColor))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .background(CommandMenuFocus { focused = true })
    .accessibilityIdentifier("shaar.devtools.commandMenu")
  }

  private var field: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12, weight: .medium))
      TextField(ShellL10n.string("Search DevTools"), text: $model.commandQuery)
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .focused($focused)
        .onSubmit(model.performSelectedCommand)
        .onExitCommand(perform: model.closeCommandMenu)
        .onMoveCommand(perform: moveSelection)
        .accessibilityIdentifier("shaar.devtools.commandQuery")
      Text(verbatim: "⇧⌘P")
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 10)
    .frame(height: 36)
    .help(
      ShellL10n.string(
        "Type to search panels, dock positions, and elements."
      )
    )
  }

  @ViewBuilder private func results(_ matches: [ShaarDevToolsCommandMatch]) -> some View {
    if matches.isEmpty {
      Text(ShellL10n.string("No matching commands"))
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .frame(height: 36)
    } else {
      let selected = selectedIndex(in: matches)
      ScrollViewReader { proxy in
        ScrollView {
          VStack(spacing: 0) {
            ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
              row(match, selected: index == selected)
                .id(index)
            }
          }
        }
        .onChange(of: model.commandSelection) { _, index in
          proxy.scrollTo(index, anchor: .center)
        }
      }
      .frame(height: listHeight(matches.count))
    }
  }

  private func listHeight(_ count: Int) -> CGFloat {
    min(280, 44 * CGFloat(count))
  }

  private func row(_ match: ShaarDevToolsCommandMatch, selected: Bool) -> some View {
    Button {
      model.perform(match)
    } label: {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 1) {
          Text(title(match))
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
          if !match.detail.isEmpty {
            Text(match.detail)
              .font(.system(size: 10, design: .monospaced))
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        Spacer(minLength: 8)
        if let group = match.hit.groupKey {
          Text(ShellL10n.string(group))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 12)
      .frame(minHeight: 32)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        if selected { Color.primary.opacity(0.08) }
      }
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("shaar.devtools.commandRow")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func title(_ match: ShaarDevToolsCommandMatch) -> String {
    guard match.hit.localizesTitle else { return match.title }
    return ShellL10n.string(match.title)
  }

  private func selectedIndex(in matches: [ShaarDevToolsCommandMatch]) -> Int {
    guard !matches.isEmpty else { return 0 }
    return min(model.commandSelection, matches.count - 1)
  }

  private func moveSelection(_ direction: MoveCommandDirection) {
    switch direction {
    case .down: model.moveCommandSelection(forward: true)
    case .up: model.moveCommandSelection(forward: false)
    default: break
    }
  }
}

/// Focuses the query when its window is on screen.
private struct CommandMenuFocus: NSViewRepresentable {
  var activate: () -> Void

  func makeNSView(context: Context) -> FocusView {
    let view = FocusView()
    view.activate = activate
    return view
  }

  func updateNSView(_ view: FocusView, context: Context) {
    view.activate = activate
    view.focusIfVisible()
  }

  final class FocusView: NSView {
    var activate: (() -> Void)?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      focusIfVisible()
    }

    func focusIfVisible() {
      guard window?.isVisible == true else { return }
      DispatchQueue.main.async { [weak self] in
        guard self?.window?.isVisible == true else { return }
        self?.activate?()
      }
    }
  }
}

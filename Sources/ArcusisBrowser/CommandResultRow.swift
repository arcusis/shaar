import AppKit
import BrowserCore
import SwiftUI

/// One launcher row: site icon, title, grey secondary text and, when selected, its action.
struct CommandResultRow: View {
  let result: CommandResult
  let subtitle: String
  let favicon: NSImage?
  let actionHint: String?

  var body: some View {
    HStack(spacing: 10) {
      icon
        .frame(width: 22)
      Text(result.title)
        .font(.system(size: 13, weight: .medium))
        .lineLimit(1)
      Text(subtitle)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer(minLength: 8)
      if let actionHint {
        hint(actionHint)
      }
    }
    .padding(.horizontal, 10)
    .frame(height: BrowserChromeLayout.resultRowHeight - 2)
    .contentShape(Rectangle())
  }

  @ViewBuilder private var icon: some View {
    if let favicon {
      Image(nsImage: favicon)
        .resizable()
        .scaledToFit()
        .frame(width: 16, height: 16)
    } else {
      Image(systemName: result.symbol)
        .font(.system(size: 14))
        .foregroundStyle(.secondary)
    }
  }

  private func hint(_ text: String) -> some View {
    HStack(spacing: 5) {
      Text(text)
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
        .fixedSize()
      Image(systemName: "return")
        .font(.system(size: 10, weight: .semibold))
    }
    .foregroundStyle(Color.accentColor)
  }
}

struct CommandSectionHeader: View {
  let title: String

  var body: some View {
    Text(title)
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 10)
      .padding(.top, 6)
      .frame(
        maxWidth: .infinity, minHeight: BrowserChromeLayout.resultSectionHeaderHeight - 2,
        alignment: .bottomLeading
      )
      .accessibilityAddTraits(.isHeader)
  }
}

/// Spotlight-style chips; selecting the active chip again clears the filter.
struct CommandFilterChips: View {
  @Bindable var store: BrowserStore

  var body: some View {
    HStack(spacing: 6) {
      ForEach(CommandFilter.allCases) { filter in
        chip(filter)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 18)
    .padding(.bottom, 12)
  }

  private func chip(_ filter: CommandFilter) -> some View {
    let isSelected = store.commandFilter == filter
    return Button {
      store.commandFilter = isSelected ? nil : filter
    } label: {
      Label(filter.title, systemImage: filter.symbol)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor : Color.primary.opacity(0.07), in: Capsule())
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .focusable(false)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("command-filter-\(filter.rawValue)")
  }
}

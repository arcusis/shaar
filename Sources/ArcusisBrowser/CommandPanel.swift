import BrowserCore
import SwiftUI

struct CommandPanel: View {
  @Bindable var store: BrowserStore
  let resultsHeight: CGFloat
  @FocusState private var searchIsFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 21, weight: .light))
          .foregroundStyle(.secondary)
        TextField("Search or enter address", text: $store.commandQuery)
          .textFieldStyle(.plain)
          .font(.system(size: 21))
          .focused($searchIsFocused)
          .onSubmit { store.acceptCommand() }
          .accessibilityIdentifier("command-search")
        Text("esc")
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
      }
      .padding(22)
      Divider()
      let results = store.results
      ScrollViewReader { proxy in
        ScrollView {
          VStack(spacing: 3) {
            if results.isEmpty {
              Text("No matching tabs or spaces")
                .foregroundStyle(.secondary)
                .padding(20)
            }
            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
              Button {
                store.perform(result.action)
              } label: {
                HStack(spacing: 12) {
                  Image(systemName: result.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                  VStack(alignment: .leading, spacing: 3) {
                    Text(result.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(result.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                      .lineLimit(
                        1)
                  }
                  Spacer()
                  if index == store.commandSelection {
                    Image(systemName: "return").foregroundStyle(.secondary)
                  }
                }
                .padding(12)
                .contentShape(Rectangle())
                .background(
                  .primary.opacity(index == store.commandSelection ? 0.07 : 0),
                  in: RoundedRectangle(cornerRadius: 8)
                )
              }
              .buttonStyle(.plain)
              .accessibilityAddTraits(index == store.commandSelection ? .isSelected : [])
              .id(result.id)
            }
          }
          .padding(8)
        }
        .frame(height: resultsHeight)
        .onChange(of: store.commandSelection) { _, index in
          guard results.indices.contains(index) else { return }
          proxy.scrollTo(results[index].id)
        }
      }
      Divider()
      HStack {
        Label(store.profileName, systemImage: "person.crop.circle")
        Spacer()
        Text("↑↓ select    ↩ open")
      }
      .font(.system(size: 10))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 16)
      .padding(.vertical, 11)
    }
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17))
    .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(.white.opacity(0.5)))
    .shadow(color: .black.opacity(0.18), radius: 30, y: 16)
    .onAppear { searchIsFocused = true }
    .onChange(of: store.commandQuery) { _, _ in store.commandSelection = 0 }
    .onKeyPress(.upArrow) {
      store.moveCommandSelection(by: -1)
      return .handled
    }
    .onKeyPress(.downArrow) {
      store.moveCommandSelection(by: 1)
      return .handled
    }
    .onExitCommand { store.dismissCommand() }
    .accessibilityLabel("Search tabs, spaces, or the web")
  }
}

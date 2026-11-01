// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import ChromiumBridge
import SwiftUI

struct PrivateBrowserWindow: View {
  @Bindable var store: PrivateBrowserStore
  let runtime: ARCChromiumRuntime
  @FocusState private var addressIsFocused: Bool
  @FocusState private var commandIsFocused: Bool
  @FocusState private var pageIsFocused: Bool
  @State private var addressDraft = ""

  var body: some View {
    HStack(spacing: 0) {
      privateSidebar
        .frame(width: BrowserChromeLayout.sidebarWidth)
      Divider().opacity(0.4)
      page
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear {
      addressDraft = store.address
      addressIsFocused = !store.showsStartPage
    }
    .onChange(of: store.address) { _, value in addressDraft = value }
    .onChange(of: store.selectedTabID) { _, _ in addressDraft = store.address }
    .onChange(of: store.pageIsFocused) { _, focused in
      if focused { pageIsFocused = true }
    }
    .onChange(of: store.commandIsOpen) { _, open in
      if open {
        addressIsFocused = false
        commandIsFocused = true
      } else {
        commandIsFocused = false
      }
    }
    .onExitCommand {
      if store.commandIsOpen {
        store.dismissCommand()
        pageIsFocused = true
      }
    }
    .modifier(PrivateHTTPWarning(store: store))
    .frame(minWidth: 760, minHeight: 520)
  }

  private var privateSidebar: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 8) {
        Image(systemName: "eye.slash.fill")
          .foregroundStyle(Color(red: 0.73, green: 0.66, blue: 0.95))
        Text("Private browsing")
          .font(.system(size: 13, weight: .semibold))
          .lineLimit(1)
      }
      .padding(.horizontal, 16)
      .padding(.top, 22)

      Text("PRIVATE TABS")
        .font(.system(size: 10, weight: .semibold))
        .tracking(0.8)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)

      ScrollView {
        VStack(spacing: 4) {
          ForEach(store.tabs) { tab in
            HStack(spacing: 8) {
              Button {
                store.selectTab(tab.id)
              } label: {
                HStack(spacing: 8) {
                  Image(systemName: "globe")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                  Text(tab.title.isEmpty || tab.title == "about:blank" ? "New tab" : tab.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                  Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              Button {
                store.closeTab(tab.id)
              } label: {
                Image(systemName: "xmark")
                  .font(.system(size: 9, weight: .semibold))
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Close private tab")
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .foregroundStyle(.primary.opacity(store.selectedTabID == tab.id ? 1 : 0.72))
            .background(
              store.selectedTabID == tab.id ? Color.accentColor.opacity(0.14) : .clear,
              in: RoundedRectangle(cornerRadius: 7))
          }
        }
        .padding(.horizontal, 8)
      }

      Button {
        store.openTab()
      } label: {
        Label("New private tab", systemImage: "plus")
          .font(.system(size: 12, weight: .medium))
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 16)

      Spacer(minLength: 0)
      Text("Private tabs stay out of your history")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
    }
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.78))
  }

  private var page: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Button {
          store.goBack()
        } label: {
          Image(systemName: "chevron.left")
        }
        .disabled(store.selectedTab?.canGoBack != true)
        Button {
          store.goForward()
        } label: {
          Image(systemName: "chevron.right")
        }
        .disabled(store.selectedTab?.canGoForward != true)
        Button {
          store.reload()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        PrivateSiteControlsButton(store: store, runtime: runtime)
        TextField("Search or enter address", text: $addressDraft)
          .textFieldStyle(.roundedBorder)
          .focused($addressIsFocused)
          .onSubmit {
            store.address = addressDraft
            store.navigate(addressDraft)
            pageIsFocused = true
          }
      }
      .buttonStyle(.borderless)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(Color(nsColor: .windowBackgroundColor))

      if let failure = store.failure {
        Text(failure).font(.callout).foregroundStyle(.red).padding(10)
      }
      Divider().opacity(0.4)
      ZStack {
        Color(nsColor: .textBackgroundColor)
        if store.showsStartPage {
          PrivateStartPage(store: store)
            .id(store.selectedTabID)
        } else if let tab = store.selectedTab {
          PrivatePageView(
            runtime: runtime, store: store, tabID: tab.id, isFocused: pageIsFocused
          )
          .focusable()
          .focused($pageIsFocused)
        }
        if store.commandIsOpen {
          Color.black.opacity(0.30)
            .ignoresSafeArea()
          VStack(alignment: .leading, spacing: 12) {
            Text("Private search")
              .font(.system(size: 14, weight: .semibold))
            TextField("Search or enter address", text: $store.commandQuery)
              .textFieldStyle(.roundedBorder)
              .focused($commandIsFocused)
              .onSubmit { store.submitCommand() }
            Text("Results open in this private window")
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
          }
          .padding(20)
          .frame(maxWidth: BrowserChromeLayout.preferredCommandWidth)
          .background(
            Color(nsColor: .windowBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
          )
          .overlay {
            RoundedRectangle(cornerRadius: 12)
              .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6))
          }
          .shadow(color: .black.opacity(0.22), radius: 24, y: 8)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .padding(.top, 20)
  }
}

private struct PrivatePageView: NSViewRepresentable {
  let runtime: ARCChromiumRuntime
  let store: PrivateBrowserStore
  let tabID: String
  let isFocused: Bool

  func makeNSView(context: Context) -> ChromiumPageContainerView {
    ChromiumPageContainerView()
  }

  func updateNSView(_ view: ChromiumPageContainerView, context: Context) {
    _ = view.attach(
      runtime.view(forPrivateTabID: tabID, windowID: store.windowID, contextID: store.contextID))
    if isFocused, view.window?.isKeyWindow == true {
      _ = runtime.focusPrivateTabID(
        tabID, windowID: store.windowID, contextID: store.contextID)
    }
  }

  static func dismantleNSView(_ view: ChromiumPageContainerView, coordinator: ()) {
    view.attach(nil)
  }
}

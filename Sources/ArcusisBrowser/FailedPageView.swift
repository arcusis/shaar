import SwiftUI

struct FailedPageView: View {
  let store: BrowserStore
  let failure: RendererFailure

  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "arrow.clockwise.circle")
        .font(.system(size: 38, weight: .light)).foregroundStyle(.secondary)
      Text("This page stopped working")
        .font(.system(size: 24, weight: .medium, design: .rounded))
      Text(failure.pageURL.host() ?? "This page")
        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
      Text(failure.message).foregroundStyle(.secondary).multilineTextAlignment(.center)
      if failure.reloading {
        ProgressView("Reloading page…")
      } else {
        Button("Reload page") { store.reloadFailedPage(failure.id) }
          .buttonStyle(.borderedProminent).disabled(!store.canReloadFailure(failure.id))
          .help("Reload (Command-R)")
      }
    }
    .padding(32).frame(maxWidth: 440)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

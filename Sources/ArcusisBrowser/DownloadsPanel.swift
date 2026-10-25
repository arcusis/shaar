import BrowserCore
import SwiftUI

struct DownloadsPanel: View {
  let store: BrowserStore
  let engine: BrowserEngine
  let profileID: UUID
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Downloads").font(.title2.weight(.semibold))
          Text(profileName).font(.callout).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      if store.session.selectedSpace.profileID != profileID {
        ContentUnavailableView("Profile changed", systemImage: "person.crop.circle")
      } else if items.isEmpty {
        ContentUnavailableView(
          "No downloads", systemImage: "arrow.down.circle",
          description: Text("Downloads for this profile appear here."))
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
              row(item).padding(.vertical, 12)
              Divider()
            }
          }
        }
      }
      if let notice = engine.downloads.notices[profileID] {
        Text(notice).font(.callout).foregroundStyle(.secondary)
      }
    }
    .padding(24).frame(width: 560, height: 440)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var items: [BrowserDownload] { engine.downloads.items(in: profileID) }
  private var profileName: String {
    store.session.profiles.first { $0.id == profileID }?.name ?? "Unavailable profile"
  }

  private func row(_ item: BrowserDownload) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: item.dangerous ? "exclamationmark.shield" : "doc")
        .font(.title2).foregroundStyle(.secondary).frame(width: 28)
      VStack(alignment: .leading, spacing: 5) {
        Text(item.filename).font(.headline).lineLimit(1).truncationMode(.middle)
        Text("\(item.source) · \(status(item))").font(.caption).foregroundStyle(.secondary)
          .lineLimit(1)
        if item.state == .downloading && !item.dangerous {
          if let progress = item.progress {
            ProgressView(value: progress)
          } else {
            ProgressView().controlSize(.small)
          }
          Text(byteStatus(item)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        if item.dangerous {
          Text("Blocked by the browser. This file cannot be opened here.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if item.canOpen {
        Button {
          engine.revealDownload(item.id, profileID: profileID, open: true)
        } label: {
          Image(systemName: "arrow.up.forward.square")
        }
        .help("Open file").accessibilityLabel("Open \(item.filename)")
        Button {
          engine.revealDownload(item.id, profileID: profileID, open: false)
        } label: {
          Image(systemName: "folder")
        }
        .help("Show in Finder").accessibilityLabel("Show \(item.filename) in Finder")
      }
      ForEach(item.actions, id: \.rawValue) { action in
        Button {
          engine.downloads.perform(
            action, id: item.id, profileID: profileID,
            selectedProfileID: store.session.selectedSpace.profileID)
        } label: {
          Image(systemName: symbol(action))
        }
        .help(label(action)).accessibilityLabel("\(label(action)): \(item.filename)")
      }
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
  }

  private func status(_ item: BrowserDownload) -> String {
    if item.dangerous { return "Blocked" }
    switch item.state {
    case .downloading: return item.paused ? "Paused" : "Downloading"
    case .finished: return "Complete"
    case .failed: return "Interrupted"
    case .cancelled: return "Cancelled"
    }
  }

  private func byteStatus(_ item: BrowserDownload) -> String {
    let received = ByteCountFormatter.string(fromByteCount: item.receivedBytes, countStyle: .file)
    guard let total = item.totalBytes else { return received }
    return "\(received) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
  }

  private func symbol(_ action: DownloadAction) -> String {
    switch action {
    case .pause: "pause.fill"
    case .resume: "play.fill"
    case .cancel: "xmark"
    case .remove: "minus.circle"
    }
  }

  private func label(_ action: DownloadAction) -> String {
    switch action {
    case .pause: "Pause"
    case .resume: "Resume"
    case .cancel: "Cancel download"
    case .remove: "Remove from list"
    }
  }
}

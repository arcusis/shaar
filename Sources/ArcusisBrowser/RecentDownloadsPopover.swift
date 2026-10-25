import AppKit
import BrowserCore
import SwiftUI

struct RecentDownloadsPopover: View {
  let items: [BrowserDownload]
  let profileID: UUID
  let selectedProfileID: () -> UUID
  let dragURL: (BrowserDownload) -> URL?
  let dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Recent Downloads").font(.headline)
        Spacer()
        Button(action: dismiss) {
          Image(systemName: "xmark").font(.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close recent downloads")
      }
      if items.isEmpty {
        Text("No recent downloads").font(.callout).foregroundStyle(.secondary)
          .padding(.vertical, 8)
      } else {
        ForEach(items.prefix(5)) { item in row(item) }
      }
    }
    .padding(12)
    .frame(width: 300, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    .shadow(color: .black.opacity(0.15), radius: 12, y: 5)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Recent downloads for current profile")
  }

  private func row(_ item: BrowserDownload) -> some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: item.dangerous ? "exclamationmark.shield" : "doc")
        .foregroundStyle(.secondary)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 3) {
        Text(item.filename).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
        Text("\(item.source) · \(status(item))")
          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        if item.state == .downloading && !item.dangerous {
          if let progress = item.progress {
            ProgressView(value: progress)
          } else {
            ProgressView().controlSize(.small)
          }
          Text(byteStatus(item)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 3)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .onDrag {
      guard selectedProfileID() == profileID, let url = dragURL(item) else {
        return NSItemProvider()
      }
      return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }
  }

  private func status(_ item: BrowserDownload) -> String {
    if item.dangerous { return "Blocked" }
    return switch item.state {
    case .downloading: item.paused ? "Paused" : "Downloading"
    case .finished: "Complete"
    case .failed: "Interrupted"
    case .cancelled: "Cancelled"
    }
  }

  private func byteStatus(_ item: BrowserDownload) -> String {
    let received = ByteCountFormatter.string(fromByteCount: item.receivedBytes, countStyle: .file)
    guard let total = item.totalBytes else { return received }
    return "\(received) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
  }
}

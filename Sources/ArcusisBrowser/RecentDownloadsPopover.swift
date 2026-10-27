import AppKit
import BrowserCore
import SwiftUI
import UniformTypeIdentifiers

struct RecentDownloadsPopover: View {
  let items: [BrowserDownload]
  let profileID: UUID
  let selectedProfileID: () -> UUID
  let dragURL: (BrowserDownload) -> URL?
  let dismiss: () -> Void
  private let referenceDate: Date

  init(
    items: [BrowserDownload], profileID: UUID, selectedProfileID: @escaping () -> UUID,
    dragURL: @escaping (BrowserDownload) -> URL?, dismiss: @escaping () -> Void,
    referenceDate: Date = .now
  ) {
    self.items = items
    self.profileID = profileID
    self.selectedProfileID = selectedProfileID
    self.dragURL = dragURL
    self.dismiss = dismiss
    self.referenceDate = referenceDate
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if items.isEmpty {
        Text("No recent downloads").font(.callout).foregroundStyle(.secondary)
          .padding(.vertical, 8)
          .padding(.trailing, 24)
      } else {
        ForEach(items.prefix(5)) { item in
          row(item).padding(.trailing, item.id == items.first?.id ? 24 : 0)
        }
      }
    }
    .padding(12)
    .frame(width: 300, alignment: .leading)
    .overlay(alignment: .topTrailing) {
      Button(action: dismiss) {
        Image(systemName: "xmark").font(.caption.weight(.semibold))
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Close recent downloads")
      .padding(6)
    }
    .background(
      Color(nsColor: .windowBackgroundColor).opacity(0.97),
      in: RoundedRectangle(cornerRadius: 12)
    )
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    .shadow(color: .black.opacity(0.15), radius: 12, y: 5)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Recent downloads for current profile")
  }

  private func row(_ item: BrowserDownload) -> some View {
    let stateLabel = status(item)
    return HStack(alignment: .center, spacing: 9) {
      if item.dangerous {
        Image(systemName: "exclamationmark.shield")
          .foregroundStyle(.secondary)
          .frame(width: 20, height: 24)
      } else {
        Image(nsImage: fileIcon(for: item))
          .resizable()
          .interpolation(.high)
          .frame(width: 20, height: 20)
      }
      VStack(alignment: .leading, spacing: item.state == .finished && !item.dangerous ? 0 : 3) {
        Text(item.filename)
          .font(.callout.weight(.medium))
          .lineLimit(1)
          .truncationMode(.middle)
        if item.state == .finished && !item.dangerous {
          Text(relativeAge(item))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else {
          Text(stateLabel)
            .font(.caption)
            .foregroundStyle(.primary)
            .lineLimit(1)
          if item.state == .downloading && !item.dangerous {
            if let progress = item.progress {
              ProgressView(value: progress)
            } else if !item.paused {
              ProgressView().controlSize(.small)
            }
            Text(byteStatus(item)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
          }
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 3)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      item.state == .finished && !item.dangerous
        ? "\(item.filename), \(relativeAge(item))"
        : accessibilityLabel(for: item, stateLabel: stateLabel)
    )
    .onDrag {
      guard selectedProfileID() == profileID, let url = dragURL(item) else {
        return NSItemProvider()
      }
      return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }
  }

  private func accessibilityLabel(for item: BrowserDownload, stateLabel: String) -> String {
    let details = item.state == .downloading && !item.dangerous ? ", \(byteStatus(item))" : ""
    return "\(item.filename), \(stateLabel)\(details), \(relativeAge(item))"
  }

  private func relativeAge(_ item: BrowserDownload) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(
      for: Date(timeIntervalSince1970: item.startTime), relativeTo: referenceDate)
  }

  private func fileIcon(for item: BrowserDownload) -> NSImage {
    let extensionName = (item.filename as NSString).pathExtension.lowercased()
    guard let type = UTType(filenameExtension: extensionName)
    else { return NSWorkspace.shared.icon(for: .data) }
    return NSWorkspace.shared.icon(for: type)
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

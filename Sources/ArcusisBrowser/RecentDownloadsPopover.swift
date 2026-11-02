// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct RecentDownloadsPopover: View {
  let items: [BrowserDownload]
  let profileID: UUID
  let selectedProfileID: () -> UUID
  let dragURL: (BrowserDownload) -> URL?
  let dismiss: () -> Void
  let backdrop: Color
  private let referenceDate: Date

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var revealed = false
  @State private var thumbnails: [String: NSImage] = [:]

  init(
    items: [BrowserDownload], profileID: UUID, selectedProfileID: @escaping () -> UUID,
    dragURL: @escaping (BrowserDownload) -> URL?, dismiss: @escaping () -> Void,
    backdrop: Color = Color(nsColor: .windowBackgroundColor),
    referenceDate: Date = .now, animatesReveal: Bool = true
  ) {
    self.items = items
    self.profileID = profileID
    self.selectedProfileID = selectedProfileID
    self.dragURL = dragURL
    self.dismiss = dismiss
    self.backdrop = backdrop
    self.referenceDate = referenceDate
    _revealed = State(initialValue: !animatesReveal)
  }

  var body: some View {
    // Arc lists the newest download closest to the footer.
    let shown = Array(items.prefix(5).reversed())
    VStack(alignment: .leading, spacing: 10) {
      if shown.isEmpty {
        Text(PanelsL10n.string("No recent downloads")).font(.callout).foregroundStyle(.secondary)
          .padding(.vertical, 8)
      } else {
        ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
          row(item)
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed || reduceMotion ? 0 : 16)
            .animation(revealAnimation(stepsFromFooter: shown.count - 1 - index), value: revealed)
        }
      }
    }
    .padding(.horizontal, 2)
    .padding(.top, 36)
    .padding(.bottom, 6)
    .frame(width: 212, alignment: .leading)
    .background { fadingBackdrop }
    .onAppear { revealed = true }
    .onExitCommand(perform: dismiss)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(PanelsL10n.string("Recent downloads for current profile"))
  }

  /// Tabs above the list fade out behind it, as in Arc.
  private var fadingBackdrop: some View {
    LinearGradient(
      stops: [
        .init(color: backdrop.opacity(0), location: 0),
        .init(color: backdrop, location: 0.16),
      ],
      startPoint: .top, endPoint: .bottom
    )
    .padding(.horizontal, -14)
  }

  private func revealAnimation(stepsFromFooter: Int) -> Animation {
    if reduceMotion { return .easeOut(duration: 0.12) }
    return .spring(response: 0.32, dampingFraction: 0.82)
      .delay(Double(stepsFromFooter) * 0.035)
  }

  private func row(_ item: BrowserDownload) -> some View {
    let stateLabel = status(item)
    let isPlainFinished = item.state == .finished && !item.dangerous
    return HStack(alignment: .center, spacing: 12) {
      preview(item)
        .frame(width: 44, height: 44)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.filename)
          .font(.system(size: 14, weight: .medium))
          .lineLimit(1)
          .truncationMode(.middle)
        if isPlainFinished {
          Text(relativeAge(item))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else {
          Text(stateLabel)
            .font(.system(size: 12))
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
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      isPlainFinished
        ? "\(item.filename), \(relativeAge(item))"
        : accessibilityLabel(for: item, stateLabel: stateLabel)
    )
    .task(id: item.id) { await loadThumbnail(item) }
    .onDrag {
      guard selectedProfileID() == profileID, let url = dragURL(item) else {
        return NSItemProvider()
      }
      return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }
  }

  @ViewBuilder
  private func preview(_ item: BrowserDownload) -> some View {
    if item.dangerous {
      Image(systemName: "exclamationmark.shield")
        .font(.system(size: 20))
        .foregroundStyle(.secondary)
    } else if let thumbnail = thumbnails[item.id] {
      Image(nsImage: thumbnail)
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    } else {
      Image(nsImage: fileIcon(for: item))
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fit)
    }
  }

  private func loadThumbnail(_ item: BrowserDownload) async {
    guard item.state == .finished, !item.dangerous, thumbnails[item.id] == nil,
      let url = dragURL(item)
    else { return }
    let request = QLThumbnailGenerator.Request(
      fileAt: url, size: CGSize(width: 44, height: 44),
      scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .all)
    guard let image = await RecentDownloadThumbnail.generate(request), !Task.isCancelled,
      selectedProfileID() == profileID
    else { return }
    thumbnails[item.id] = image
  }

  private func accessibilityLabel(for item: BrowserDownload, stateLabel: String) -> String {
    let details = item.state == .downloading && !item.dangerous ? [byteStatus(item)] : []
    let formatter = ListFormatter()
    formatter.locale = PanelsL10n.formattingLocale()
    return formatter.string(from: [item.filename, stateLabel] + details + [relativeAge(item)])
      ?? ([item.filename, stateLabel] + details + [relativeAge(item)]).joined(separator: ", ")
  }

  private func relativeAge(_ item: BrowserDownload) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    formatter.locale = PanelsL10n.formattingLocale()
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
    if item.dangerous { return PanelsL10n.string("Blocked") }
    return switch item.state {
    case .downloading: PanelsL10n.string(item.paused ? "Paused" : "Downloading")
    case .finished: PanelsL10n.string("Complete")
    case .failed: PanelsL10n.string("Interrupted")
    case .cancelled: PanelsL10n.string("Cancelled")
    }
  }

  private func byteStatus(_ item: BrowserDownload) -> String {
    let received = PanelsL10n.byteCount(item.receivedBytes)
    guard let total = item.totalBytes else { return received }
    return PanelsL10n.format(
      "%@ of %@", .string(received),
      .string(PanelsL10n.byteCount(total)))
  }
}

private enum RecentDownloadThumbnail {
  static func generate(_ request: QLThumbnailGenerator.Request) async -> NSImage? {
    let handle = RecentDownloadThumbnailRequest(request)
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
          continuation.resume(
            returning: representation.map { NSImage(cgImage: $0.cgImage, size: .zero) })
        }
      }
    } onCancel: {
      handle.cancel()
    }
  }
}

private final class RecentDownloadThumbnailRequest: @unchecked Sendable {
  private let request: QLThumbnailGenerator.Request

  init(_ request: QLThumbnailGenerator.Request) { self.request = request }

  func cancel() { QLThumbnailGenerator.shared.cancel(request) }
}

import AppKit
import SwiftUI

struct ProfileExtensionsSection: View {
  let model: ExtensionManagerModel?
  let onAddExtensions: () -> Void
  @State private var detailID: String?

  var body: some View {
    Group {
      if let model, let item = model.extensions.first(where: { $0.id == detailID }) {
        ExtensionDetails(model: model, item: item) { detailID = nil }
      } else {
        VStack(alignment: .leading, spacing: 0) {
          if let model {
            ExtensionManagerList(
              model: model, canRun: false, run: { _ in }, showDetails: { detailID = $0 }
            )
            .frame(maxHeight: 220)
          } else {
            ContentUnavailableView(
              "No Extensions", systemImage: "puzzlepiece.extension",
              description: Text("Extensions you add appear here for this profile.")
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
          }
          Button(action: onAddExtensions) {
            Label("Add Extensions…", systemImage: "plus")
          }
          .buttonStyle(.link)
          .padding(.top, 8)
          .disabled(model == nil)
        }
        .task { model?.refresh() }
      }
    }
  }
}

struct ExtensionManagerList: View {
  let model: ExtensionManagerModel
  let canRun: Bool
  let run: (String) -> Void
  let showDetails: (String) -> Void

  var body: some View {
    if model.extensions.isEmpty {
      ContentUnavailableView(
        "No Extensions", systemImage: "puzzlepiece.extension",
        description: Text("Extensions you add appear here for this profile.")
      )
      .padding(.vertical, 12)
    } else {
      ScrollView {
        VStack(spacing: 2) {
          ForEach(model.extensions) { item in
            ExtensionRow(
              item: item, icon: model.icons[item.id],
              pinned: model.pinnedIDs.contains(item.id), canRun: canRun,
              actions: ExtensionRowActions(
                run: { run(item.id) },
                setPinned: { model.setPinned(item.id, pinned: $0) },
                setEnabled: { model.setEnabled(item.id, enabled: $0) },
                showDetails: { showDetails(item.id) }))
          }
        }
        .padding(8)
      }
      .frame(maxHeight: 360)
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct ExtensionDetails: View {
  let model: ExtensionManagerModel
  let item: ManagedExtension
  let back: () -> Void
  @State private var confirmsRemoval = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button(action: back) {
        Label("Extensions", systemImage: "chevron.left")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      HStack(spacing: 12) {
        ExtensionIcon(image: model.icons[item.id], size: 40)
        VStack(alignment: .leading, spacing: 2) {
          Text(item.name).font(.headline).lineLimit(2)
          Text("Version \(item.version)").font(.caption).foregroundStyle(.secondary)
        }
      }
      if !item.description.isEmpty {
        Text(item.description).font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      detailSection("Permissions", values: item.permissions)
      detailSection("Site access", values: item.hostPermissions)
      Divider()
      Button("Remove Extension…", role: .destructive) { confirmsRemoval = true }
        .disabled(!item.mayDisable)
    }
    .padding(16)
    .confirmationDialog(
      "Remove \(item.name)?", isPresented: $confirmsRemoval, titleVisibility: .visible
    ) {
      Button("Remove", role: .destructive) {
        model.remove(item.id)
        back()
      }
    } message: {
      Text("Its data in this profile is deleted. You can add it again from the Chrome Web Store.")
    }
  }

  @ViewBuilder
  private func detailSection(_ title: String, values: [String]) -> some View {
    if !values.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        ForEach(values, id: \.self) { value in
          Text(value).font(.caption).lineLimit(1).truncationMode(.middle)
        }
      }
    }
  }
}

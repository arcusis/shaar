// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FavoriteTile {
  let id: UUID
  let title: String
  let url: URL
  let image: NSImage?
  var pageID: UUID? = nil
}

struct ProfileFavoriteDrag: Codable, Transferable, Equatable {
  let profileID: UUID
  let dragSessionID: UUID
  let favoriteID: UUID
  let favoriteIDs: [UUID]

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .json)
  }
}

struct ProfileFavoritesAccessibilityOverrides {
  let reduceMotion: Bool
  let reduceTransparency: Bool
}

struct ProfileFavoritesGrid: View {
  let favorites: [FavoriteTile]
  let selectedID: UUID?
  let profileID: UUID
  let dragSessionID: UUID
  let onSelect: (UUID) -> Void
  let onReset: (UUID) -> Void
  let onRemove: (UUID) -> Void
  let onMoveBefore: (UUID, UUID?) -> Void
  let onTabDrop: (SidebarTransfer, UUID?) -> Bool
  let accessibilityOverrides: ProfileFavoritesAccessibilityOverrides?
  let activeDrag: SidebarTransfer?
  let dropRefusal: String?
  let onBeginDrag: (SidebarTransfer) -> SidebarTransfer
  @Namespace private var tileNamespace
  @Environment(\.sidebarMotionNamespace) private var sharedNamespace
  @State private var gridWidth: CGFloat = 212
  @State private var insertionIndex: Int?
  @State private var draggedOut = false
  @State private var isTargeted = false
  @State private var multipleItems = false

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.layoutDirection) private var layoutDirection
  @State private var hoveredID: UUID?

  init(
    favorites: [FavoriteTile],
    selectedID: UUID?,
    profileID: UUID,
    dragSessionID: UUID,
    onSelect: @escaping (UUID) -> Void,
    onReset: @escaping (UUID) -> Void,
    onRemove: @escaping (UUID) -> Void,
    onMoveBefore: @escaping (UUID, UUID?) -> Void,
    onTabDrop: @escaping (SidebarTransfer, UUID?) -> Bool = { _, _ in false },
    accessibilityOverrides: ProfileFavoritesAccessibilityOverrides? = nil,
    activeDrag: SidebarTransfer? = nil,
    dropRefusal: String? = nil,
    onBeginDrag: @escaping (SidebarTransfer) -> SidebarTransfer = { $0 }
  ) {
    self.activeDrag = activeDrag
    self.dropRefusal = dropRefusal
    self.onBeginDrag = onBeginDrag
    self.favorites = favorites
    self.selectedID = selectedID
    self.profileID = profileID
    self.dragSessionID = dragSessionID
    self.onSelect = onSelect
    self.onReset = onReset
    self.onRemove = onRemove
    self.onMoveBefore = onMoveBefore
    self.onTabDrop = onTabDrop
    self.accessibilityOverrides = accessibilityOverrides
  }

  private var draggedFavoriteID: UUID? {
    guard case .favorite(let payload) = activeDrag,
      payload.profileID == profileID, payload.dragSessionID == dragSessionID,
      payload.favoriteIDs == favorites.map(\.id)
    else { return nil }
    return payload.favoriteID
  }

  private var remainingFavorites: [FavoriteTile] {
    favorites.filter { $0.id != draggedFavoriteID }
  }

  private var refusal: String? {
    if multipleItems { return ShellL10n.string("Single tabs only") }
    return dropRefusal
  }

  private var motionReduced: Bool { reduceMotion || accessibilityOverrides?.reduceMotion == true }
  private var motion: Animation {
    motionReduced ? .easeOut(duration: 0.16) : .spring(response: 0.32, dampingFraction: 0.82)
  }

  private enum EntryID: Hashable {
    case tile(UUID)
    case gap
  }
  private var entries: [EntryID] {
    var ids = (insertionIndex != nil || draggedOut ? remainingFavorites : favorites)
      .map { EntryID.tile($0.id) }
    if let insertionIndex { ids.insert(.gap, at: min(insertionIndex, ids.count)) }
    return ids
  }

  private func destination(at point: CGPoint, width: CGFloat) -> Int {
    FavoritesGridLayout.insertionIndex(
      at: point, count: remainingFavorites.count + 1, width: width,
      rtl: layoutDirection == .rightToLeft)
  }

  var body: some View {
    let transparencyReduced =
      reduceTransparency || accessibilityOverrides?.reduceTransparency == true
    VStack(spacing: 0) {
      FavoritesGridLayout {
        ForEach(entries, id: \.self) { entry in
          switch entry {
          case .tile(let id):
            if let favorite = favorites.first(where: { $0.id == id }) {
              tile(favorite, reduceMotion: motionReduced, reduceTransparency: transparencyReduced)
                .sidebarPageMotion(id: favorite.pageID ?? favorite.id, reduceMotion: motionReduced)

            }
          case .gap:
            RoundedRectangle(cornerRadius: 12)
              .fill(Color.accentColor.opacity(0.1))
              .overlay {
                RoundedRectangle(cornerRadius: 12)
                  .strokeBorder(
                    Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
              }
              .accessibilityLabel(ShellL10n.string("Drop to add to Favorites"))
              .transition(.opacity)
          }
        }
      }
      // Replacing the layout under Reduce Motion crossfades instead of interpolating frames.
      .id(motionReduced ? String(describing: entries) : "favorites")
      .transition(.opacity)
      .padding(.vertical, favorites.isEmpty && insertionIndex == nil ? 0 : 1)
      .frame(minHeight: favorites.isEmpty ? (activeDrag == nil ? 8 : 44) : 0)
      .contentShape(Rectangle())
      .accessibilityLabel(SettingsL10n.string("Favorite pages"))
      .coordinateSpace(name: "sidebarFavoriteViewport")
      .background {
        GeometryReader { geometry in
          Color.clear.preference(
            key: SidebarFavoriteRevealFramesPreferenceKey.self,
            value: SidebarRevealFrames(viewport: CGRect(origin: .zero, size: geometry.size)))
        }
      }
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: {
        gridWidth = $0
      }
      .dropDestination(for: SidebarTransfer.self) { items, point in
        defer { clearPreview() }
        guard items.count == 1, let item = items.first, refusal == nil else { return false }
        let remaining: [FavoriteTile]
        if case .favorite(let payload) = item {
          remaining = favorites.filter { $0.id != payload.favoriteID }
        } else {
          remaining = favorites
        }
        let index = FavoritesGridLayout.insertionIndex(
          at: point, count: remaining.count + 1, width: gridWidth,
          rtl: layoutDirection == .rightToLeft)
        let before = remaining.indices.contains(index) ? remaining[index].id : nil
        if case .favorite(let payload) = item {
          guard
            Self.accepts(
              payload, before: before, favorites: favorites,
              profileID: profileID, dragSessionID: dragSessionID)
          else { return false }
          onMoveBefore(payload.favoriteID, before)
          return true
        }
        return onTabDrop(item, before)
      }
      .onDropSessionUpdated { drop in
        switch drop.phase {
        case .entering, .active:
          isTargeted = true
          multipleItems = drop.itemsCount != 1
          draggedOut = false
          insertionIndex =
            refusal == nil
            ? destination(at: drop.location, width: gridWidth) : nil
        case .exiting:
          isTargeted = false
          insertionIndex = nil
          draggedOut = draggedFavoriteID != nil
        case .ended(.cancel), .ended(.forbidden), .dataTransferCompleted:
          clearPreview()
        case .ended:
          break
        @unknown default:
          clearPreview()
        }
      }
      .dropConfiguration { _ in
        DropConfiguration(operation: refusal == nil ? .move : .forbidden)
      }
      .overlay {
        if favorites.isEmpty, activeDrag != nil, !isTargeted {
          SidebarDropHint(
            title: refusal ?? ShellL10n.string("Drop to add to Favorites"),
            symbol: refusal == nil ? "star" : "nosign", isTargeted: false)
        }
        if isTargeted, let refusal {
          Label(refusal, systemImage: "nosign")
            .font(.caption).foregroundStyle(.red).padding(6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .allowsHitTesting(false)
            .transition(.opacity)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .environment(\.sidebarMotionNamespace, sharedNamespace ?? tileNamespace)
    .preference(
      key: FavoritesGridPresentationKey.self,
      value: FavoritesGridPresentation(
        ids: entries.map { if case .tile(let id) = $0 { id } else { nil } },
        refusal: isTargeted ? refusal : nil)
    )
    .animation(motion, value: entries)
    .animation(motion, value: isTargeted)
    .animation(motion, value: activeDrag != nil)
    .onChange(of: activeDrag) { _, item in
      if item == nil { clearPreview() }
    }
  }

  private func clearPreview() {
    insertionIndex = nil
    draggedOut = false
    isTargeted = false
    multipleItems = false
  }

  private func tile(
    _ favorite: FavoriteTile, reduceMotion: Bool, reduceTransparency: Bool
  ) -> some View {
    let isSelected = favorite.id == selectedID
    let isHovered = favorite.id == hoveredID

    return GeometryReader { geometry in
      Button {
        onSelect(favorite.id)
      } label: {
        favoriteIcon(favorite, reduceTransparency: reduceTransparency)
          .frame(width: 22, height: 22)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(
            tileBackground(
              isSelected: isSelected, isHovered: isHovered,
              reduceTransparency: reduceTransparency),
            in: RoundedRectangle(cornerRadius: 12)
          )
          .contentShape(RoundedRectangle(cornerRadius: 12))
      }
      .buttonStyle(ProfileFavoriteTileButtonStyle(reduceMotion: reduceMotion))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .help(
        SettingsL10n.format("%@\n%@", .string(favorite.title), .string(favorite.url.absoluteString))
      )
      .accessibilityLabel(
        SettingsL10n.format("%@, %@", .string(favorite.title), .string(favorite.url.absoluteString))
      )
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      .draggable(onBeginDrag(.favorite(dragPayload(for: favorite))))
      .onHover { isHovered in
        if isHovered {
          hoveredID = favorite.id
        } else if hoveredID == favorite.id {
          hoveredID = nil
        }
      }
      .contextMenu {
        Button(SettingsL10n.string("Move Left")) { movePhysical(favorite.id, left: true) }
          .disabled(isPhysicalMoveUnavailable(favorite.id, left: true))
        Button(SettingsL10n.string("Move Right")) { movePhysical(favorite.id, left: false) }
          .disabled(isPhysicalMoveUnavailable(favorite.id, left: false))
        Divider()
        Button(SettingsL10n.string("Reset to Original Address")) { onReset(favorite.id) }
        Button(SettingsL10n.string("Remove Favorite (keeps page)"), role: .destructive) {
          onRemove(favorite.id)
        }
      }
    }
    .frame(height: FavoritesGridLayout.height)
    .background {
      GeometryReader { geometry in
        if isSelected {
          Color.clear.preference(
            key: SidebarFavoriteRevealFramesPreferenceKey.self,
            value: SidebarRevealFrames(
              selected: geometry.frame(in: .named("sidebarFavoriteViewport")),
              selectedID: favorite.id))
        }
      }
    }
  }

  private func favoriteIcon(_ favorite: FavoriteTile, reduceTransparency: Bool) -> some View {
    Group {
      if let image = favorite.image {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .frame(width: 22, height: 22)
      } else {
        Text(initial(for: favorite.title))
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 22, height: 22)
          .background(
            reduceTransparency
              ? Color(nsColor: .controlBackgroundColor)
              : Color.primary.opacity(0.055))
      }
    }
  }

  private func initial(for title: String) -> String {
    String(title.first.map { String($0).uppercased() } ?? "•")
  }

  private func tileBackground(
    isSelected: Bool, isHovered: Bool, reduceTransparency: Bool
  ) -> some ShapeStyle {
    if reduceTransparency {
      return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
    }
    if isSelected {
      return AnyShapeStyle(Color.primary.opacity(0.12))
    }
    return AnyShapeStyle(Color.primary.opacity(isHovered ? 0.12 : 0.08))
  }

  private func dragPayload(for favorite: FavoriteTile) -> ProfileFavoriteDrag {
    ProfileFavoriteDrag(
      profileID: profileID,
      dragSessionID: dragSessionID,
      favoriteID: favorite.id,
      favoriteIDs: favorites.map(\.id))
  }

  private func index(of favoriteID: UUID) -> Int? {
    favorites.firstIndex { $0.id == favoriteID }
  }

  private func moveLeft(_ favoriteID: UUID) {
    guard let index = index(of: favoriteID), index > 0 else { return }
    onMoveBefore(favoriteID, favorites[index - 1].id)
  }

  private func moveRight(_ favoriteID: UUID) {
    guard let index = index(of: favoriteID), index < favorites.count - 1 else { return }
    let beforeNext = favorites.indices.contains(index + 2) ? favorites[index + 2].id : nil
    onMoveBefore(favoriteID, beforeNext)
  }

  private func movePhysical(_ favoriteID: UUID, left: Bool) {
    let moveLeftInOrder = Self.moveLeftInOrder(
      physicalLeft: left, isRightToLeft: layoutDirection == .rightToLeft)
    if moveLeftInOrder { moveLeft(favoriteID) } else { moveRight(favoriteID) }
  }

  private func isPhysicalMoveUnavailable(_ favoriteID: UUID, left: Bool) -> Bool {
    guard let index = index(of: favoriteID) else { return true }
    let moveLeftInOrder = Self.moveLeftInOrder(
      physicalLeft: left, isRightToLeft: layoutDirection == .rightToLeft)
    return moveLeftInOrder ? index == 0 : index == favorites.count - 1
  }

  static func moveLeftInOrder(physicalLeft: Bool, isRightToLeft: Bool) -> Bool {
    physicalLeft != isRightToLeft
  }

  static func dropTargetBefore(
    targetID: UUID, dropX: CGFloat, tileWidth: CGFloat, favorites: [FavoriteTile],
    isRightToLeft: Bool = false
  ) -> UUID? {
    guard let targetIndex = favorites.firstIndex(where: { $0.id == targetID }) else { return nil }
    let logicalDropX = isRightToLeft ? tileWidth - dropX : dropX
    if logicalDropX < tileWidth / 2 { return targetID }
    let nextIndex = targetIndex + 1
    return favorites.indices.contains(nextIndex) ? favorites[nextIndex].id : nil
  }

  static func accepts(
    _ payload: ProfileFavoriteDrag,
    before targetID: UUID?,
    favorites: [FavoriteTile],
    profileID: UUID,
    dragSessionID: UUID
  ) -> Bool {
    let ids = favorites.map(\.id)
    guard payload.profileID == profileID,
      payload.dragSessionID == dragSessionID,
      payload.favoriteIDs == ids,
      let sourceIndex = ids.firstIndex(of: payload.favoriteID)
    else { return false }
    if let targetID, !ids.contains(targetID) { return false }
    guard targetID != payload.favoriteID else { return false }

    var reorderedIDs = ids
    let sourceID = reorderedIDs.remove(at: sourceIndex)
    let destinationIndex =
      targetID.flatMap { reorderedIDs.firstIndex(of: $0) } ?? reorderedIDs.endIndex
    reorderedIDs.insert(sourceID, at: destinationIndex)
    return reorderedIDs != ids
  }
}

private struct ProfileFavoriteTileButtonStyle: ButtonStyle {
  let reduceMotion: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background {
        RoundedRectangle(cornerRadius: 12)
          .fill(Color.primary.opacity(configuration.isPressed ? 0.13 : 0))
      }
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
  }
}

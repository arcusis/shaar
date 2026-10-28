import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FavoriteTile {
  let id: UUID
  let title: String
  let url: URL
  let image: NSImage?
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
  @State private var currentSelectionID: UUID?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
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
    accessibilityOverrides: ProfileFavoritesAccessibilityOverrides? = nil
  ) {
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
    _currentSelectionID = State(initialValue: selectedID)
  }

  private static let columns = Array(
    repeating: GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 8), count: 2)
  private static let tileHeight: CGFloat = 62
  private static let maximumRows = 2

  var body: some View {
    let motionReduced = reduceMotion || accessibilityOverrides?.reduceMotion == true
    let transparencyReduced =
      reduceTransparency || accessibilityOverrides?.reduceTransparency == true
    Group {
      if !favorites.isEmpty {
        ScrollViewReader { favoriteScroll in
          ScrollView(.vertical) {
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 8) {
              ForEach(favorites, id: \.id) { favorite in
                tile(favorite, reduceMotion: motionReduced, reduceTransparency: transparencyReduced)
                  .id(favorite.id)
              }
            }
            .padding(.vertical, 1)
          }
          .scrollIndicators(.hidden)
          .frame(height: gridHeight)
          .accessibilityLabel("Favorite pages")
          .coordinateSpace(name: "sidebarFavoriteViewport")
          .background {
            GeometryReader { geometry in
              Color.clear.preference(
                key: SidebarFavoriteRevealFramesPreferenceKey.self,
                value: SidebarRevealFrames(
                  viewport: CGRect(origin: .zero, size: geometry.size)))
            }
          }
          .onAppear {
            if let selectedID, favorites.contains(where: { $0.id == selectedID }) {
              favoriteScroll.scrollTo(selectedID)
            }
          }
          .onChange(of: selectedID) { _, id in
            currentSelectionID = id
            guard let id, favorites.contains(where: { $0.id == id }) else { return }
            DispatchQueue.main.async {
              guard currentSelectionID == id,
                favorites.contains(where: { $0.id == id })
              else { return }
              if motionReduced {
                favoriteScroll.scrollTo(id)
              } else {
                withAnimation(.easeOut(duration: 0.12)) { favoriteScroll.scrollTo(id) }
              }
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .animation(motionReduced ? nil : .easeOut(duration: 0.12), value: hoveredID)
  }

  private var gridHeight: CGFloat {
    let rows = min((favorites.count + 1) / 2, Self.maximumRows)
    return CGFloat(rows) * Self.tileHeight + CGFloat(max(rows - 1, 0)) * 8 + 2
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
      .help("\(favorite.title)\n\(favorite.url.absoluteString)")
      .accessibilityLabel("\(favorite.title), \(favorite.url.absoluteString)")
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      .draggable(dragPayload(for: favorite))
      .dropDestination(for: ProfileFavoriteDrag.self) { drops, point in
        guard drops.count == 1, let payload = drops.first else { return false }
        let beforeID = Self.dropTargetBefore(
          targetID: favorite.id, dropX: point.x, tileWidth: geometry.size.width,
          favorites: favorites)
        guard
          Self.accepts(
            payload, before: beforeID, favorites: favorites,
            profileID: profileID, dragSessionID: dragSessionID)
        else { return false }
        onMoveBefore(payload.favoriteID, beforeID)
        return true
      }
      .dropDestination(for: SidebarTransfer.self) { items, point in
        guard items.count == 1, let item = items.first else { return false }
        return onTabDrop(
          item,
          Self.dropTargetBefore(
            targetID: favorite.id, dropX: point.x, tileWidth: geometry.size.width,
            favorites: favorites))
      }
      .onHover { isHovered in
        if isHovered {
          hoveredID = favorite.id
        } else if hoveredID == favorite.id {
          hoveredID = nil
        }
      }
      .contextMenu {
        Button("Move Left") { moveLeft(favorite.id) }
          .disabled(index(of: favorite.id) == 0)
        Button("Move Right") { moveRight(favorite.id) }
          .disabled(index(of: favorite.id) == favorites.count - 1)
        Divider()
        Button("Reset to Original Address") { onReset(favorite.id) }
        Button("Remove Favorite (keeps page)", role: .destructive) { onRemove(favorite.id) }
      }
    }
    .frame(height: Self.tileHeight)
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

  static func dropTargetBefore(
    targetID: UUID, dropX: CGFloat, tileWidth: CGFloat, favorites: [FavoriteTile]
  ) -> UUID? {
    guard let targetIndex = favorites.firstIndex(where: { $0.id == targetID }) else { return nil }
    if dropX < tileWidth / 2 { return targetID }
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

import Foundation

/// Owns only recent-card presentation; download authority stays in DownloadsModel.
struct RecentDownloadsPresentation {
  enum HoverTarget {
    case anchor, card
  }

  private(set) var profileID: UUID
  private(set) var isOpen = false
  private(set) var isPinned = false
  private(set) var anchorHovered = false
  private(set) var cardHovered = false
  private(set) var epoch: UInt64 = 0
  private var generation: UInt64 = 0

  init(profileID: UUID) {
    self.profileID = profileID
  }

  /// Returns a close token only when the pointer leaves an owned region.
  mutating func hover(
    _ target: HoverTarget, inside: Bool, profileID: UUID, epoch: UInt64
  ) -> UInt64? {
    guard profileID == self.profileID, epoch == self.epoch else { return nil }
    generation &+= 1
    switch target {
    case .anchor: anchorHovered = inside
    case .card: cardHovered = inside
    }
    if inside {
      isOpen = true
      return nil
    }
    return generation
  }

  mutating func finishHoverLeave(token: UInt64, profileID: UUID, epoch: UInt64) {
    guard profileID == self.profileID, epoch == self.epoch, token == generation else { return }
    if !anchorHovered && !cardHovered && !isPinned { isOpen = false }
  }

  /// A keyboard or accessibility activation pins an already-hovered card.
  mutating func toggle(profileID: UUID, epoch: UInt64) {
    guard profileID == self.profileID, epoch == self.epoch else { return }
    if isPinned {
      dismiss(profileID: profileID, epoch: epoch)
    } else {
      generation &+= 1
      isPinned = true
      isOpen = true
    }
  }

  mutating func dismiss(profileID: UUID, epoch: UInt64) {
    guard profileID == self.profileID, epoch == self.epoch else { return }
    generation &+= 1
    isOpen = false
    isPinned = false
    anchorHovered = false
    cardHovered = false
  }

  mutating func selectProfile(_ profileID: UUID) {
    generation &+= 1
    epoch &+= 1
    self.profileID = profileID
    isOpen = false
    isPinned = false
    anchorHovered = false
    cardHovered = false
  }
}

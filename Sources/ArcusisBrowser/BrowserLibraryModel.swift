import BrowserCore
import Foundation
import Observation

struct LibraryKey: Hashable {
  let profileID: UUID
  let section: LibrarySection
}

enum LibraryMutation {
  case bookmark([String: Any])
  case deleteHistory(String)

  var section: LibrarySection {
    switch self {
    case .bookmark: .bookmarks
    case .deleteHistory: .history
    }
  }
}

@MainActor @Observable
final class BrowserLibraryModel {
  private(set) var bookmarks: [UUID: BookmarkTree] = [:]
  private(set) var history: [UUID: [BrowserHistoryEntry]] = [:]
  private(set) var notices: [LibraryKey: String] = [:]
  private(set) var watchNotices: [LibraryKey: String] = [:]
  private(set) var loading: Set<LibraryKey> = []
  private(set) var mutating: Set<LibraryKey> = []
  private(set) var historyLimits: [UUID: Int] = [:]
  @ObservationIgnored var onLoad:
    ((LibraryKey, Int, @escaping @MainActor (Result<Any, Error>) -> Void) -> Void)?
  @ObservationIgnored var onMutation:
    ((UUID, LibraryMutation, @escaping @MainActor (String?) -> Void) -> Void)?
  @ObservationIgnored private var generations: [LibraryKey: UUID] = [:]
  @ObservationIgnored private var pendingRefresh: [LibraryKey: Task<Void, Never>] = [:]
  @ObservationIgnored private var dirty: Set<LibraryKey> = []

  func notice(_ profile: UUID, section: LibrarySection) -> String? {
    let key = LibraryKey(profileID: profile, section: section)
    return notices[key] ?? watchNotices[key]
  }

  func refresh(_ profile: UUID, section: LibrarySection) {
    let key = LibraryKey(profileID: profile, section: section)
    guard !mutating.contains(key) else {
      dirty.insert(key)
      return
    }
    pendingRefresh.removeValue(forKey: key)?.cancel()
    dirty.remove(key)
    let token = UUID()
    generations[key] = token
    loading.insert(key)
    notices[key] = nil
    let limit = historyLimits[profile] ?? 500
    guard let onLoad else {
      loading.remove(key)
      notices[key] = "The browser engine is unavailable."
      return
    }
    onLoad(key, limit) { [weak self] result in
      guard let self, self.generations[key] == token else { return }
      self.loading.remove(key)
      do {
        let payload = try result.get()
        switch section {
        case .bookmarks:
          guard let object = payload as? [String: Any] else {
            throw LibraryDataError.invalidBookmarks
          }
          self.bookmarks[profile] = try BookmarkTree(profileID: profile, payload: object)
        case .history:
          guard let rows = payload as? [[String: Any]] else {
            throw LibraryDataError.invalidHistory
          }
          let entries = try rows.map { try BrowserHistoryEntry(profileID: profile, payload: $0) }
          guard Set(entries.map(\.id)).count == entries.count else {
            throw LibraryDataError.invalidHistory
          }
          self.history[profile] = entries.sorted { $0.lastVisit > $1.lastVisit }
        }
      } catch { self.notices[key] = error.localizedDescription }
      if self.dirty.remove(key) != nil { self.invalidate(profile, section: section) }
    }
  }

  func invalidate(_ profile: UUID, section: LibrarySection) {
    let key = LibraryKey(profileID: profile, section: section)
    if loading.contains(key) || mutating.contains(key) {
      dirty.insert(key)
      return
    }
    guard pendingRefresh[key] == nil else { return }
    pendingRefresh[key] = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
      self?.refresh(profile, section: section)
    }
  }

  func serviceFailed(_ profile: UUID, section: LibrarySection, message: String) {
    watchNotices[LibraryKey(profileID: profile, section: section)] = message
  }

  func hasMoreHistory(_ profile: UUID) -> Bool {
    (history[profile]?.count ?? 0) >= (historyLimits[profile] ?? 500)
      && (historyLimits[profile] ?? 500) < Int(Int32.max)
  }

  func loadMoreHistory(_ profile: UUID) {
    let key = LibraryKey(profileID: profile, section: .history)
    guard !loading.contains(key), hasMoreHistory(profile) else { return }
    historyLimits[profile] = min((historyLimits[profile] ?? 500) * 2, Int(Int32.max))
    refresh(profile, section: .history)
  }

  @discardableResult
  func mutate(
    _ mutation: LibraryMutation, profile: UUID, completion: @escaping @MainActor (Bool) -> Void
  )
    -> Bool
  {
    let key = LibraryKey(profileID: profile, section: mutation.section)
    guard !mutating.contains(key), let onMutation else { return false }
    mutating.insert(key)
    pendingRefresh.removeValue(forKey: key)?.cancel()
    dirty.remove(key)
    generations[key] = UUID()
    loading.remove(key)
    notices[key] = nil
    onMutation(profile, mutation) { [weak self] error in
      guard let self else { return }
      self.mutating.remove(key)
      // The pinned bookmark apply endpoint does not emit change events for its own writes.
      self.refresh(profile, section: mutation.section)
      if let error { self.notices[key] = error }
      completion(error == nil)
    }
    return true
  }
}

import Foundation

enum TabMaterializationPolicy {
  enum Decision: Equatable {
    case keepLive
    case materialize
    case deferred
  }

  static func decision(isSelected: Bool, isLive: Bool, lazy: Bool) -> Decision {
    if isLive { return .keepLive }
    if !lazy || isSelected { return .materialize }
    return .deferred
  }
}

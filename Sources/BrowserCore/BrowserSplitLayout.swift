import Foundation

/// Panes laid out side by side (columns) or stacked top to bottom (rows).
public enum SplitAxis: String, Codable, Sendable {
  case columns
  case rows
}

/// Where a new pane lands relative to an existing one.
public enum SplitEdge: String, CaseIterable, Sendable {
  case left, right, top, bottom

  var axis: SplitAxis { self == .left || self == .right ? .columns : .rows }
  var insertsAfter: Bool { self == .right || self == .bottom }
}

/// A split layout tree. Groups hold two or more children with weights that sum to one.
public indirect enum SplitNode: Equatable, Sendable {
  case pane(UUID)
  case group(SplitAxis, [SplitNode], [Double])

  public var paneIDs: [UUID] {
    switch self {
    case .pane(let id): [id]
    case .group(_, let children, _): children.flatMap(\.paneIDs)
    }
  }

  var isValid: Bool {
    guard Set(paneIDs).count == paneIDs.count else { return false }
    return isWellFormed
  }

  private var isWellFormed: Bool {
    switch self {
    case .pane: return true
    case .group(_, let children, let weights):
      guard children.count >= 2, weights.count == children.count,
        weights.allSatisfy({ $0.isFinite && $0 > 0 }),
        abs(weights.reduce(0, +) - 1) < 0.001
      else { return false }
      return children.allSatisfy(\.isWellFormed)
    }
  }

  /// Removes a pane; groups left with one child collapse into that child.
  func removing(_ id: UUID) -> SplitNode? {
    switch self {
    case .pane(let paneID):
      return paneID == id ? nil : self
    case .group(let axis, let children, let weights):
      var kept: [(SplitNode, Double)] = []
      for (child, weight) in zip(children, weights) {
        if let remaining = child.removing(id) { kept.append((remaining, weight)) }
      }
      if kept.isEmpty { return nil }
      if kept.count == 1 { return kept[0].0 }
      return .group(axis, kept.map(\.0), Self.normalized(kept.map(\.1)))
    }
  }

  /// Places a new pane beside `target`, sharing the target's space.
  func inserting(_ id: UUID, beside target: UUID, edge: SplitEdge) -> SplitNode {
    switch self {
    case .pane(let paneID):
      guard paneID == target else { return self }
      let pair: [SplitNode] = edge.insertsAfter ? [self, .pane(id)] : [.pane(id), self]
      return .group(edge.axis, pair, [0.5, 0.5])
    case .group(let axis, var children, var weights):
      if axis == edge.axis, let index = children.firstIndex(of: .pane(target)) {
        let half = weights[index] / 2
        weights[index] = half
        let position = edge.insertsAfter ? index + 1 : index
        children.insert(.pane(id), at: position)
        weights.insert(half, at: position)
        return .group(axis, children, weights)
      }
      return .group(axis, children.map { $0.inserting(id, beside: target, edge: edge) }, weights)
    }
  }

  /// Replaces the weights of the group found by following child indexes from the root.
  func settingWeights(_ newWeights: [Double], at path: [Int]) -> SplitNode {
    guard case .group(let axis, var children, let weights) = self else { return self }
    guard let first = path.first else {
      guard newWeights.count == weights.count,
        newWeights.allSatisfy({ $0.isFinite && $0 > 0 })
      else { return self }
      return .group(axis, children, Self.normalized(newWeights))
    }
    guard children.indices.contains(first) else { return self }
    children[first] = children[first].settingWeights(newWeights, at: Array(path.dropFirst()))
    return .group(axis, children, weights)
  }

  static func evenly(_ axis: SplitAxis, _ children: [SplitNode]) -> SplitNode {
    if children.count == 1 { return children[0] }
    return .group(axis, children, Array(repeating: 1 / Double(children.count), count: children.count))
  }

  static func normalized(_ weights: [Double]) -> [Double] {
    let total = weights.reduce(0, +)
    guard total > 0 else { return weights.map { _ in 1 / Double(weights.count) } }
    return weights.map { $0 / total }
  }
}

extension SplitNode: Codable {
  private enum CodingKeys: String, CodingKey {
    case pane, axis, children, weights
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    if let id = try c.decodeIfPresent(UUID.self, forKey: .pane) {
      self = .pane(id)
      return
    }
    self = .group(
      try c.decode(SplitAxis.self, forKey: .axis),
      try c.decode([SplitNode].self, forKey: .children),
      try c.decode([Double].self, forKey: .weights))
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .pane(let id):
      try c.encode(id, forKey: .pane)
    case .group(let axis, let children, let weights):
      try c.encode(axis, forKey: .axis)
      try c.encode(children, forKey: .children)
      try c.encode(weights, forKey: .weights)
    }
  }
}

/// Ready-made arrangements offered by the split controls, keeping pane order.
public enum SplitLayoutPreset: String, CaseIterable, Identifiable, Sendable {
  case columns
  case rows
  case mainLeading
  case mainTop
  case grid

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .columns: "Side by Side"
    case .rows: "Stacked"
    case .mainLeading: "One Left, Rest Stacked"
    case .mainTop: "One Top, Rest Side by Side"
    case .grid: "Grid"
    }
  }

  public var symbol: String {
    switch self {
    case .columns: "rectangle.split.3x1"
    case .rows: "rectangle.split.1x2"
    case .mainLeading: "rectangle.lefthalf.inset.filled"
    case .mainTop: "rectangle.tophalf.inset.filled"
    case .grid: "rectangle.split.2x2"
    }
  }

  public static func available(paneCount: Int) -> [SplitLayoutPreset] {
    switch paneCount {
    case 2: [.columns, .rows]
    case 3: [.columns, .rows, .mainLeading, .mainTop]
    case 4: allCases
    default: []
    }
  }

  public func node(for ids: [UUID]) -> SplitNode? {
    guard Self.available(paneCount: ids.count).contains(self) else { return nil }
    let panes = ids.map(SplitNode.pane)
    switch self {
    case .columns: return .evenly(.columns, panes)
    case .rows: return .evenly(.rows, panes)
    case .mainLeading: return .evenly(.columns, [panes[0], .evenly(.rows, Array(panes.dropFirst()))])
    case .mainTop: return .evenly(.rows, [panes[0], .evenly(.columns, Array(panes.dropFirst()))])
    case .grid:
      return .evenly(.rows, [.evenly(.columns, Array(panes[0..<2])), .evenly(.columns, Array(panes[2...]))])
    }
  }

  /// The preset whose shape matches the layout, ignoring weights.
  public static func matching(_ node: SplitNode) -> SplitLayoutPreset? {
    let ids = node.paneIDs
    return available(paneCount: ids.count).first { preset in
      preset.node(for: ids).map { $0.shape == node.shape } ?? false
    }
  }
}

extension SplitNode {
  fileprivate var shape: String {
    switch self {
    case .pane(let id): id.uuidString
    case .group(let axis, let children, _):
      "\(axis.rawValue)(\(children.map(\.shape).joined(separator: ",")))"
    }
  }
}

// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import ShaarEngineABI
import SwiftUI

enum ShaarDOMDropKind: Equatable {
  case before
  case inside
}

struct ShaarDOMDropPreview: Equatable {
  let rowID: Int
  let kind: ShaarDOMDropKind
}

enum ShaarDOMDrop {
  /// Matches the element row label, so the drop band uses the same height.
  static let rowHeight: CGFloat = 24

  static func kind(nodeType: Int, height: CGFloat, y: CGFloat) -> ShaarDOMDropKind {
    guard nodeType == 1, height > 0 else { return .before }
    let edge = height / 4
    if y >= edge, y < height - edge { return .inside }
    return .before
  }

  static func destination(
    draggedID: Int, rowID: Int, kind: ShaarDOMDropKind, nodes: [Int: ShaarDOMNode]
  ) -> (parentID: Int, before: Int?)? {
    guard draggedID != rowID, let row = nodes[rowID] else { return nil }
    switch kind {
    case .inside:
      guard row.nodeType == 1 else { return nil }
      guard allowed(id: draggedID, parentID: rowID, before: nil, nodes: nodes) else { return nil }
      return (rowID, nil)
    case .before:
      guard let parentID = row.parentID else { return nil }
      guard allowed(id: draggedID, parentID: parentID, before: rowID, nodes: nodes) else {
        return nil
      }
      return (parentID, rowID)
    }
  }

  static func allowed(
    id: Int, parentID: Int, before siblingID: Int?, nodes: [Int: ShaarDOMNode]
  ) -> Bool {
    guard id != parentID, nodes[id] != nil, nodes[parentID] != nil else { return false }
    if encloses(id, node: parentID, nodes: nodes) { return false }
    guard let siblingID else { return true }
    guard siblingID != id, nodes[siblingID]?.parentID == parentID else { return false }
    return true
  }

  private static func encloses(_ ancestor: Int, node: Int, nodes: [Int: ShaarDOMNode]) -> Bool {
    var current = nodes[node]?.parentID
    var steps = 0
    while let parent = current, steps < 64 {
      if parent == ancestor { return true }
      current = nodes[parent]?.parentID
      steps += 1
    }
    return false
  }
}

@MainActor struct ShaarDOMRowDropDelegate: DropDelegate {
  let row: ShaarDOMNode
  let nodes: [Int: ShaarDOMNode]
  @Binding var preview: ShaarDOMDropPreview?
  let move: (Int, Int, Int?) -> Void

  func dropUpdated(info: DropInfo) -> DropProposal? {
    let kind = ShaarDOMDrop.kind(
      nodeType: row.nodeType, height: ShaarDOMDrop.rowHeight, y: info.location.y)
    preview = ShaarDOMDropPreview(rowID: row.id, kind: kind)
    return DropProposal(operation: .move)
  }

  func dropExited(info: DropInfo) {
    guard preview?.rowID == row.id else { return }
    preview = nil
  }

  func performDrop(info: DropInfo) -> Bool {
    let kind = ShaarDOMDrop.kind(
      nodeType: row.nodeType, height: ShaarDOMDrop.rowHeight, y: info.location.y)
    preview = nil
    guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
    let nodes = nodes
    let rowID = row.id
    provider.loadObject(ofClass: NSString.self) { object, _ in
      guard let text = object as? String, let draggedID = Int(text) else { return }
      let dragged = draggedID
      Task { @MainActor in
        _ = ShaarDOMDrag.apply(
          draggedID: dragged, rowID: rowID, kind: kind, nodes: nodes, move: move)
      }
    }
    return true
  }
}

enum ShaarDOMDrag {
  @MainActor static func apply(
    draggedID: Int, rowID: Int, kind: ShaarDOMDropKind, nodes: [Int: ShaarDOMNode],
    move: (Int, Int, Int?) -> Void
  ) -> Bool {
    guard
      let destination = ShaarDOMDrop.destination(
        draggedID: draggedID, rowID: rowID, kind: kind, nodes: nodes)
    else { return false }
    move(draggedID, destination.parentID, destination.before)
    return true
  }
}

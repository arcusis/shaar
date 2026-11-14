// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreFoundation
import Foundation

private func domEventInteger(_ value: Any?) -> Int? {
  guard let number = value as? NSNumber,
    CFGetTypeID(number) != CFBooleanGetTypeID()
  else { return nil }
  return Int(exactly: number.doubleValue)
}

private func domEventBoolean(_ value: Any?) -> Bool? {
  guard let number = value as? NSNumber,
    CFGetTypeID(number) == CFBooleanGetTypeID()
  else { return nil }
  return number.boolValue
}

public enum ShaarDOMRelation: String, Sendable {
  case child
  case shadowRoot
  case frameDocument
}

public struct ShaarDOMAttribute: Equatable, Sendable {
  public let name: String
  public let value: String

  public init(name: String, value: String) {
    self.name = name
    self.value = value
  }
}

public struct ShaarDOMNode: Equatable, Identifiable, Sendable {
  public let id: Int
  public let parentID: Int?
  public let relation: ShaarDOMRelation
  public let nodeType: Int
  public let name: String
  public let value: String
  public let attributes: [ShaarDOMAttribute]
  public let childCount: Int
  public let childrenIDs: [Int]
  /// Blink's id for this node. It survives a new inspector session and dies when the node does.
  public let backendNodeID: Int?

  public init(
    id: Int, parentID: Int?, relation: ShaarDOMRelation, nodeType: Int, name: String,
    value: String, attributes: [ShaarDOMAttribute], childCount: Int, childrenIDs: [Int],
    backendNodeID: Int? = nil
  ) {
    self.id = id
    self.parentID = parentID
    self.relation = relation
    self.nodeType = nodeType
    self.name = name
    self.value = value
    self.attributes = attributes
    self.childCount = childCount
    self.childrenIDs = childrenIDs
    self.backendNodeID = backendNodeID
  }

  public var canExpand: Bool { childCount > 0 || !childrenIDs.isEmpty }
  public var attributeSummary: String {
    attributes.prefix(3).map { "\($0.name)=\"\($0.value)\"" }.joined(separator: " ")
  }

  public static func decode(
    _ fields: [String: Any], parentID: Int?, relation: ShaarDOMRelation,
    childrenIDs: [Int] = []
  ) -> Self? {
    let count: Int
    if let rawCount = fields["childNodeCount"] {
      if let number = rawCount as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
        return nil
      }
      guard let parsedCount = rawCount as? Int else { return nil }
      count = parsedCount
    } else {
      count = childrenIDs.count
    }
    guard let id = fields["nodeId"] as? Int, id > 0,
      let type = fields["nodeType"] as? Int, (1...12).contains(type),
      let name = fields["nodeName"] as? String, !name.isEmpty, name.utf8.count <= 128,
      let value = fields["nodeValue"] as? String, value.utf8.count <= 4_096,
      (0...20_000).contains(count)
    else { return nil }
    let raw: [String]
    if let value = fields["attributes"] {
      guard let attributes = value as? [String] else { return nil }
      raw = attributes
    } else {
      raw = []
    }
    guard raw.count <= 64, raw.count.isMultiple(of: 2) else { return nil }
    var attributes: [ShaarDOMAttribute] = []
    for index in stride(from: 0, to: raw.count, by: 2) {
      guard !raw[index].isEmpty, raw[index].utf8.count <= 256,
        raw[index + 1].utf8.count <= 16_384
      else { return nil }
      attributes.append(ShaarDOMAttribute(name: raw[index], value: raw[index + 1]))
    }
    return Self(
      id: id, parentID: parentID, relation: relation, nodeType: type,
      name: name, value: value, attributes: attributes,
      childCount: count, childrenIDs: childrenIDs,
      backendNodeID: backendNodeID(fields["backendNodeId"]))
  }

  private static func backendNodeID(_ value: Any?) -> Int? {
    if let value = value as? Int, value > 0 { return value }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
      return nil
    }
    let parsed = number.intValue
    guard parsed > 0 else { return nil }
    return parsed
  }

  public func replacing(
    value: String? = nil, attributes: [ShaarDOMAttribute]? = nil,
    childCount: Int? = nil, childrenIDs: [Int]? = nil
  ) -> Self {
    Self(
      id: id, parentID: parentID, relation: relation, nodeType: nodeType,
      name: name, value: value ?? self.value, attributes: attributes ?? self.attributes,
      childCount: childCount ?? self.childCount, childrenIDs: childrenIDs ?? self.childrenIDs,
      backendNodeID: backendNodeID)
  }
}

public struct ShaarDOMSnapshot: Equatable, Sendable {
  public let rootID: Int
  public let nodes: [ShaarDOMNode]

  public static func decode(_ result: [String: Any]) -> Self? {
    guard let root = result["root"] as? [String: Any] else { return nil }
    var nodes: [ShaarDOMNode] = []
    var seen: Set<Int> = []
    guard
      let rootID = append(
        root, parentID: nil, relation: .child,
        depth: 0, nodes: &nodes, seen: &seen)
    else { return nil }
    return Self(rootID: rootID, nodes: nodes)
  }

  static func decodeSubtree(_ fields: [String: Any], parentID: Int) -> [ShaarDOMNode]? {
    var nodes: [ShaarDOMNode] = []
    var seen: Set<Int> = []
    guard
      append(
        fields, parentID: parentID, relation: .child,
        depth: 0, nodes: &nodes, seen: &seen) != nil
    else { return nil }
    return nodes
  }

  private static func append(
    _ fields: [String: Any], parentID: Int?, relation: ShaarDOMRelation,
    depth: Int, nodes: inout [ShaarDOMNode], seen: inout Set<Int>
  ) -> Int? {
    guard depth <= 40, nodes.count < 20_000,
      let id = fields["nodeId"] as? Int, id > 0, seen.insert(id).inserted
    else { return nil }
    let children = fields["children"] as? [[String: Any]] ?? []
    let shadows = fields["shadowRoots"] as? [[String: Any]] ?? []
    let frame = fields["contentDocument"] as? [String: Any]
    guard children.count <= 2_000, shadows.count <= 32 else { return nil }
    var childIDs: [Int] = []
    for child in children {
      guard
        let childID = append(
          child, parentID: id, relation: .child,
          depth: depth + 1, nodes: &nodes, seen: &seen)
      else { return nil }
      childIDs.append(childID)
    }
    for shadow in shadows {
      guard
        let childID = append(
          shadow, parentID: id, relation: .shadowRoot,
          depth: depth + 1, nodes: &nodes, seen: &seen)
      else { return nil }
      childIDs.append(childID)
    }
    if let frame {
      guard
        let childID = append(
          frame, parentID: id, relation: .frameDocument,
          depth: depth + 1, nodes: &nodes, seen: &seen)
      else { return nil }
      childIDs.append(childID)
    }
    guard
      let node = ShaarDOMNode.decode(
        fields, parentID: parentID, relation: relation, childrenIDs: childIDs)
    else { return nil }
    nodes.append(node)
    return id
  }
}

public enum ShaarDOMMutation: Equatable, Sendable {
  case documentUpdated
  case childInserted(parentID: Int, previousID: Int, node: ShaarDOMNode)
  case childRemoved(parentID: Int, nodeID: Int)
  case childrenSet(parentID: Int, nodes: [ShaarDOMNode])
  case attributeModified(nodeID: Int, name: String, value: String)
  case characterDataModified(nodeID: Int, value: String)
  case childCountUpdated(nodeID: Int, count: Int)
}

public struct ShaarDOMEvent: Equatable, Sendable {
  public let sequence: UInt64
  public let leaseID: UInt32
  public let mutation: ShaarDOMMutation
  public let truncated: Bool
}

public enum ShaarDOMEventRouter {
  public static func decode(
    _ event: ShaarCopiedEvent, scope: ShaarNavigationScope,
    windowID: String, tabID: String, leaseID: UInt32,
    afterSequence: UInt64 = 0
  ) -> ShaarDOMEvent? {
    guard event.kind == 14, event.sequence > afterSequence,
      event.profileID == Data(scope.profileID.utf8),
      event.sessionID == Data((scope.sessionID ?? "").utf8),
      event.windowID == Data(windowID.utf8), event.tabID == Data(tabID.utf8),
      event.payloadJSON.count <= 65_536,
      let root = try? JSONSerialization.jsonObject(with: event.payloadJSON) as? [String: Any],
      Set(root.keys) == ["schemaVersion", "kind", "eventID", "leaseID", "data"],
      domEventInteger(root["schemaVersion"]) == 1,
      root["kind"] as? String == "panelEvent",
      let rawLeaseID = domEventInteger(root["leaseID"]), rawLeaseID >= 0,
      rawLeaseID <= Int(UInt32.max), UInt32(rawLeaseID) == leaseID,
      let id = domEventInteger(root["eventID"]), (20...28).contains(id),
      let fields = root["data"] as? [String: Any],
      let truncated = domEventBoolean(fields["truncated"]),
      let mutation = decodeMutation(id, fields)
    else { return nil }
    return ShaarDOMEvent(
      sequence: event.sequence, leaseID: leaseID,
      mutation: mutation, truncated: truncated)
  }

  private static func decodeMutation(_ id: Int, _ fields: [String: Any]) -> ShaarDOMMutation? {
    let keys = Set(fields.keys).subtracting(["truncated"])
    if id == 20, keys.isEmpty { return .documentUpdated }
    if id == 21 || id == 26 {
      guard keys == ["parentNodeId", "previousNodeId", "node"],
        let parent = positive(fields["parentNodeId"]),
        let previous = fields["previousNodeId"] as? Int, previous >= 0,
        let rawNode = fields["node"] as? [String: Any],
        let node = ShaarDOMNode.decode(
          rawNode, parentID: parent,
          relation: id == 26 ? .shadowRoot : .child)
      else { return nil }
      return .childInserted(parentID: parent, previousID: previous, node: node)
    }
    if id == 22 || id == 27 {
      guard keys == ["parentNodeId", "nodeId"],
        let parent = positive(fields["parentNodeId"]),
        let node = positive(fields["nodeId"])
      else { return nil }
      return .childRemoved(parentID: parent, nodeID: node)
    }
    if id == 25 {
      guard keys == ["parentNodeId", "nodes"],
        let parent = positive(fields["parentNodeId"]),
        let raw = fields["nodes"] as? [[String: Any]], raw.count <= 256
      else { return nil }
      var nodes: [ShaarDOMNode] = []
      for fields in raw {
        guard let subtree = ShaarDOMSnapshot.decodeSubtree(fields, parentID: parent),
          nodes.count + subtree.count <= 512
        else { return nil }
        nodes.append(contentsOf: subtree)
      }
      guard Set(nodes.map(\.id)).count == nodes.count else { return nil }
      return .childrenSet(parentID: parent, nodes: nodes)
    }
    if id == 23 {
      guard keys == ["nodeId", "name", "value"],
        let node = positive(fields["nodeId"]),
        let name = short(fields["name"], limit: 256), !name.isEmpty,
        let value = short(fields["value"])
      else { return nil }
      return .attributeModified(nodeID: node, name: name, value: value)
    }
    if id == 24 {
      guard keys == ["nodeId", "value"],
        let node = positive(fields["nodeId"]), let value = short(fields["value"])
      else { return nil }
      return .characterDataModified(nodeID: node, value: value)
    }
    if id == 28 {
      guard keys == ["nodeId", "childNodeCount"],
        let node = positive(fields["nodeId"]),
        let count = fields["childNodeCount"] as? Int, (0...20_000).contains(count)
      else { return nil }
      return .childCountUpdated(nodeID: node, count: count)
    }
    return nil
  }

  private static func positive(_ value: Any?) -> Int? {
    guard let value = value as? Int, value > 0 else { return nil }
    return value
  }

  private static func short(_ value: Any?, limit: Int = 4_096) -> String? {
    guard let value = value as? String, value.utf8.count <= limit else { return nil }
    return value
  }
}

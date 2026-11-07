// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreFoundation
import Foundation

struct ShaarHeapConstructor: Equatable, Identifiable, Sendable {
  let name: String
  let count: Int
  let selfBytes: Int64
  var id: String { name }
}

struct ShaarHeapSnapshotSummary: Equatable, Sendable {
  let totalBytes: Int64
  let nodeCount: Int
  let constructors: [ShaarHeapConstructor]
}

enum ShaarHeapSnapshotError: LocalizedError, Equatable {
  case malformed(String)

  var errorDescription: String? {
    switch self {
    case .malformed(let detail): detail
    }
  }
}

enum ShaarHeapByteTotal {
  static func add(_ size: Int64, to total: Int64) throws -> Int64 {
    if size < 0 {
      throw ShaarHeapSnapshotError.malformed("The heap snapshot contains a negative size.")
    }
    let (sum, overflowed) = total.addingReportingOverflow(size)
    if overflowed {
      throw ShaarHeapSnapshotError.malformed("The heap snapshot size overflowed.")
    }
    return sum
  }
}

enum ShaarByteCount {
  static func format(_ bytes: Int64) -> String {
    if bytes < 0 { return "\(bytes) B" }
    if bytes < 1024 { return "\(bytes) B" }
    let value = Double(bytes)
    if bytes < 1024 * 1024 {
      return String(format: "%.1f KB", value / 1024)
    }
    if bytes < 1024 * 1024 * 1024 {
      return String(format: "%.1f MB", value / 1_048_576)
    }
    return String(format: "%.1f GB", value / 1_073_741_824)
  }
}

enum ShaarMemoryFixture {
  static func snapshotData() -> Data {
    encode(document(samples: nil))
  }

  static func allocationProfileData() -> Data {
    encode(document(samples: [0, 5]))
  }

  private static func document(samples: [Int]?) -> [String: Any] {
    var root: [String: Any] = [
      "snapshot": [
        "meta": [
          "node_fields": ["type", "name", "id", "self_size", "edge_count"],
          "node_types": [["hidden", "array", "string", "object", "code", "closure"]],
          "sample_fields": ["timestamp_us", "last_assigned_id"],
        ],
        "node_count": 5,
      ],
      "nodes": [
        3, 1, 1, 2000, 0,
        3, 2, 2, 800, 0,
        3, 2, 10, 400, 0,
        3, 3, 11, 1500, 0,
        2, 0, 12, 100, 0,
      ],
      "strings": ["", "Window", "Array", "HTMLDivElement"],
    ]
    if let samples {
      root["samples"] = samples
    }
    return root
  }

  private static func encode(_ object: [String: Any]) -> Data {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else {
      preconditionFailure("memory fixture did not encode")
    }
    return data
  }
}

private struct ShaarHeapNodeRecord {
  let name: String
  let id: Int64
  let selfBytes: Int64
}

private struct ShaarHeapNodeLayout {
  let fieldCount: Int
  let typeIndex: Int
  let nameIndex: Int
  let idIndex: Int
  let sizeIndex: Int
  let typeNames: [String]
}

enum ShaarHeapSnapshotReader {
  static func summary(from data: Data) throws -> ShaarHeapSnapshotSummary {
    let parsed = try nodeRecords(decodedRoot(data))
    let constructors = try groupedConstructors(parsed.records)
    var total: Int64 = 0
    for constructor in constructors {
      total = try ShaarHeapByteTotal.add(constructor.selfBytes, to: total)
    }
    return ShaarHeapSnapshotSummary(
      totalBytes: total, nodeCount: parsed.nodeCount, constructors: constructors)
  }

  static func allocations(from data: Data) throws -> [ShaarHeapConstructor] {
    let root = try decodedRoot(data)
    let baseline = try allocationBaseline(root)
    let parsed = try nodeRecords(root)
    let allocated = parsed.records.filter { $0.id > baseline }
    return try groupedConstructors(allocated)
  }
}

private func decodedRoot(_ data: Data) throws -> [String: Any] {
  let object: Any
  do {
    object = try JSONSerialization.jsonObject(with: data)
  } catch {
    throw ShaarHeapSnapshotError.malformed("The heap snapshot is invalid.")
  }
  guard let root = object as? [String: Any] else {
    throw ShaarHeapSnapshotError.malformed("The heap snapshot is invalid.")
  }
  return root
}

private func snapshotParts(_ root: [String: Any]) throws -> (
  snapshot: [String: Any], meta: [String: Any]
) {
  guard let snapshot = root["snapshot"] as? [String: Any],
    let meta = snapshot["meta"] as? [String: Any]
  else {
    throw ShaarHeapSnapshotError.malformed("The heap snapshot is invalid.")
  }
  return (snapshot, meta)
}

private func declaredNodeCount(snapshot: [String: Any], meta: [String: Any]) throws -> Int {
  let raw = wholeNumber(snapshot["node_count"]) ?? wholeNumber(meta["node_count"])
  guard let raw else {
    throw ShaarHeapSnapshotError.malformed("The heap snapshot is missing a node count.")
  }
  if raw < 0 {
    throw ShaarHeapSnapshotError.malformed("The heap snapshot node count is invalid.")
  }
  if raw > 2_000_000 {
    throw ShaarHeapSnapshotError.malformed("The heap snapshot is too large.")
  }
  return Int(raw)
}

private func nodeLayout(_ meta: [String: Any]) throws -> ShaarHeapNodeLayout {
  let fields = try stringList(
    meta["node_fields"], missing: "The heap snapshot is missing node fields.")
  if fields.count < 4 || fields.count > 32 {
    throw ShaarHeapSnapshotError.malformed("The heap snapshot node field count is invalid.")
  }
  guard let typeValue = (meta["node_types"] as? [Any])?.first else {
    throw ShaarHeapSnapshotError.malformed("The heap snapshot is missing node types.")
  }
  let typeNames = try stringList(typeValue, missing: "The heap snapshot is missing node types.")
  if typeNames.isEmpty {
    throw ShaarHeapSnapshotError.malformed("The heap snapshot is missing node types.")
  }
  return ShaarHeapNodeLayout(
    fieldCount: fields.count,
    typeIndex: try fieldIndex("type", fields),
    nameIndex: try fieldIndex("name", fields),
    idIndex: try fieldIndex("id", fields),
    sizeIndex: try fieldIndex("self_size", fields),
    typeNames: typeNames)
}

private func nodeRecords(_ root: [String: Any]) throws -> (
  records: [ShaarHeapNodeRecord], nodeCount: Int
) {
  let parts = try snapshotParts(root)
  let layout = try nodeLayout(parts.meta)
  let nodeCount = try declaredNodeCount(snapshot: parts.snapshot, meta: parts.meta)
  guard let nodes = root["nodes"] as? [Any] else {
    throw ShaarHeapSnapshotError.malformed("The heap snapshot node count does not match.")
  }
  if nodes.count != nodeCount * layout.fieldCount {
    throw ShaarHeapSnapshotError.malformed("The heap snapshot node count does not match.")
  }
  let strings = try stringList(root["strings"], missing: "The heap snapshot is missing strings.")
  var records: [ShaarHeapNodeRecord] = []
  records.reserveCapacity(nodeCount)
  for index in 0..<nodeCount {
    let base = index * layout.fieldCount
    let type = try requiredNumber(nodes[base + layout.typeIndex])
    let name = try requiredNumber(nodes[base + layout.nameIndex])
    let id = try requiredNumber(nodes[base + layout.idIndex])
    let size = try requiredNumber(nodes[base + layout.sizeIndex])
    let label = try constructorName(
      type: type, name: name, typeNames: layout.typeNames, strings: strings)
    records.append(ShaarHeapNodeRecord(name: label, id: id, selfBytes: size))
  }
  return (records, nodeCount)
}

private func allocationBaseline(_ root: [String: Any]) throws -> Int64 {
  let parts = try snapshotParts(root)
  guard
    let fields = try? stringList(
      parts.meta["sample_fields"], missing: "The allocation profile has no samples."),
    let idField = fields.firstIndex(of: "last_assigned_id"),
    let samples = root["samples"] as? [Any],
    samples.count >= fields.count,
    let baseline = wholeNumber(samples[idField])
  else {
    throw ShaarHeapSnapshotError.malformed("The allocation profile has no samples.")
  }
  return baseline
}

private func groupedConstructors(_ records: [ShaarHeapNodeRecord]) throws -> [ShaarHeapConstructor]
{
  var counts: [String: Int] = [:]
  var bytes: [String: Int64] = [:]
  for record in records {
    counts[record.name, default: 0] += 1
    bytes[record.name] = try ShaarHeapByteTotal.add(record.selfBytes, to: bytes[record.name] ?? 0)
  }
  return counts.keys.map { name in
    ShaarHeapConstructor(name: name, count: counts[name] ?? 0, selfBytes: bytes[name] ?? 0)
  }.sorted(by: constructorOrder)
}

private func constructorOrder(_ lhs: ShaarHeapConstructor, _ rhs: ShaarHeapConstructor) -> Bool {
  if lhs.selfBytes != rhs.selfBytes { return lhs.selfBytes > rhs.selfBytes }
  return lhs.name < rhs.name
}

private func constructorName(
  type: Int64, name: Int64, typeNames: [String], strings: [String]
) throws -> String {
  if type < 0 || type >= Int64(typeNames.count) {
    throw ShaarHeapSnapshotError.malformed("The heap snapshot has a node type out of range.")
  }
  let typeName = typeNames[Int(type)]
  if typeName == "string" || typeName == "concatenated string" || typeName == "sliced string" {
    return "(string)"
  }
  if name < 0 || name >= Int64(strings.count) {
    throw ShaarHeapSnapshotError.malformed("The heap snapshot has a node name out of range.")
  }
  let raw = strings[Int(name)]
  if raw.isEmpty { return "(anonymous)" }
  return raw
}

private func stringList(_ value: Any?, missing: String) throws -> [String] {
  guard let items = value as? [Any] else {
    throw ShaarHeapSnapshotError.malformed(missing)
  }
  var names: [String] = []
  names.reserveCapacity(items.count)
  for item in items {
    guard let name = item as? String else {
      throw ShaarHeapSnapshotError.malformed(missing)
    }
    names.append(name)
  }
  return names
}

private func fieldIndex(_ name: String, _ fields: [String]) throws -> Int {
  guard let index = fields.firstIndex(of: name) else {
    throw ShaarHeapSnapshotError.malformed("The heap snapshot is missing the \(name) field.")
  }
  return index
}

private func requiredNumber(_ value: Any?) throws -> Int64 {
  guard let number = wholeNumber(value) else {
    throw ShaarHeapSnapshotError.malformed("The heap snapshot node values are invalid.")
  }
  return number
}

private func wholeNumber(_ value: Any?) -> Int64? {
  guard let number = value as? NSNumber else { return nil }
  if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
  let double = number.doubleValue
  if !double.isFinite || double.rounded() != double { return nil }
  if double > Double(Int64.max) || double < Double(Int64.min) { return nil }
  return number.int64Value
}

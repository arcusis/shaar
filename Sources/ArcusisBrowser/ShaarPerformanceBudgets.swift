// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation

struct ShaarPerformanceBudgetConfiguration: Codable, Equatable {
  var schemaVersion = 1
  var routes: [ShaarRouteBudget]
}

struct ShaarRouteBudget: Codable, Equatable, Identifiable {
  var route: String
  var lcpMilliseconds: Double?
  var inpMilliseconds: Double?
  var cls: Double?
  var javascriptBytes: Int?
  var requestCount: Int?

  var id: String { route }

  func validate() throws {
    guard route.utf8.count <= 2_048, route.hasPrefix("/"), route == "/" || !route.hasPrefix("//"),
      !route.contains("#"), !route.contains("?")
    else { throw ShaarPerformanceBudgetError.invalidRoute }
    let limits = [lcpMilliseconds, inpMilliseconds, cls]
    guard limits.allSatisfy({ $0 == nil || ($0!.isFinite && $0! >= 0) }),
      javascriptBytes.map({ $0 >= 0 }) ?? true,
      requestCount.map({ $0 >= 0 }) ?? true
    else { throw ShaarPerformanceBudgetError.invalidLimit }
  }

  func evaluate(
    lcpMilliseconds: Double?, inpMilliseconds: Double?, cls: Double?,
    javascriptBytes: Int?, requestCount: Int?
  ) -> ShaarPerformanceBudgetResult {
    let metrics = [
      ShaarBudgetMetric(
        name: "LCP", actual: lcpMilliseconds, limit: self.lcpMilliseconds, unit: "ms"),
      ShaarBudgetMetric(
        name: "INP", actual: inpMilliseconds, limit: self.inpMilliseconds, unit: "ms"),
      ShaarBudgetMetric(name: "CLS", actual: cls, limit: self.cls, unit: ""),
      ShaarBudgetMetric(
        name: "JavaScript", actual: javascriptBytes.map(Double.init),
        limit: self.javascriptBytes.map(Double.init), unit: "bytes"),
      ShaarBudgetMetric(
        name: "Requests", actual: requestCount.map(Double.init),
        limit: self.requestCount.map(Double.init), unit: "requests"),
    ].filter { $0.limit != nil }
    return ShaarPerformanceBudgetResult(route: route, metrics: metrics)
  }
}

enum ShaarBudgetMetricStatus: String, Codable {
  case pass, over, unavailable
}

struct ShaarBudgetMetric: Codable, Equatable, Identifiable {
  let name: String
  let actual: Double?
  let limit: Double?
  let unit: String

  var id: String { name }
  var status: ShaarBudgetMetricStatus {
    guard let actual, let limit, actual.isFinite else { return .unavailable }
    return actual <= limit ? .pass : .over
  }
}

struct ShaarPerformanceBudgetResult: Codable, Equatable {
  let route: String
  let metrics: [ShaarBudgetMetric]
  var passed: Int { metrics.filter { $0.status == .pass }.count }
  var failed: Int { metrics.filter { $0.status == .over }.count }
  var unavailable: Int { metrics.filter { $0.status == .unavailable }.count }
}

struct ShaarPerformanceBudgetReport: Codable {
  let generatedAt: Date
  let route: String
  let passed: Int
  let failed: Int
  let unavailable: Int
  let metrics: [ShaarBudgetMetric]

  init(result: ShaarPerformanceBudgetResult, generatedAt: Date = Date()) {
    self.generatedAt = generatedAt
    route = result.route
    passed = result.passed
    failed = result.failed
    unavailable = result.unavailable
    metrics = result.metrics
  }
}

@MainActor @Observable
final class ShaarPerformanceBudgetStatusRegistry {
  static let shared = ShaarPerformanceBudgetStatusRegistry()
  private(set) var results: [UUID: ShaarPerformanceBudgetResult] = [:]

  func result(for tabID: UUID) -> ShaarPerformanceBudgetResult? { results[tabID] }
  func set(_ result: ShaarPerformanceBudgetResult?, for tabID: UUID) { results[tabID] = result }
}

enum ShaarPerformanceBudgetError: LocalizedError {
  case invalidRoute
  case invalidLimit
  case unsupportedVersion
  case invalidFile

  var errorDescription: String? {
    switch self {
    case .invalidRoute: "Budget routes must be exact paths beginning with /."
    case .invalidLimit: "Budget limits must be zero or greater."
    case .unsupportedVersion: "This budgets file uses an unsupported schema version."
    case .invalidFile: "The budgets file is too large or is not a regular file."
    }
  }
}

struct ShaarPerformanceBudgetStore {
  func fileURL(in project: URL) -> URL {
    project.appending(path: ".shaar/budgets.json")
  }

  func load(from project: URL) throws -> ShaarPerformanceBudgetConfiguration {
    let file = fileURL(in: project)
    guard FileManager.default.fileExists(atPath: file.path) else {
      return ShaarPerformanceBudgetConfiguration(routes: [])
    }
    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, let size = values.fileSize, size <= 1_048_576 else {
      throw ShaarPerformanceBudgetError.invalidFile
    }
    let data = try Data(contentsOf: file)
    guard data.count <= 1_048_576 else { throw ShaarPerformanceBudgetError.invalidFile }
    let configuration = try JSONDecoder().decode(
      ShaarPerformanceBudgetConfiguration.self, from: data)
    try validate(configuration)
    return configuration
  }

  func save(_ configuration: ShaarPerformanceBudgetConfiguration, to project: URL) throws {
    try validate(configuration)
    let directory = project.appending(path: ".shaar", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(configuration)
    guard data.count <= 1_048_576 else { throw ShaarPerformanceBudgetError.invalidFile }
    try data.write(to: fileURL(in: project), options: .atomic)
  }

  private func validate(_ configuration: ShaarPerformanceBudgetConfiguration) throws {
    guard configuration.schemaVersion == 1 else {
      throw ShaarPerformanceBudgetError.unsupportedVersion
    }
    guard configuration.routes.count <= 500,
      Set(configuration.routes.map(\.route)).count == configuration.routes.count
    else { throw ShaarPerformanceBudgetError.invalidRoute }
    for route in configuration.routes { try route.validate() }
  }
}

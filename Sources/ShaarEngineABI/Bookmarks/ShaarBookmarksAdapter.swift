// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreFoundation
import Foundation

public enum ShaarBookmarkOperation: UInt32, Sendable {
  case tree = 500
  case apply = 501
  case watch = 502
}

/// Transport boundary for the single shaar_submit ABI entry point.
/// Implementations copy result bytes before returning from the C callback.
@MainActor public protocol ShaarBookmarksTransport {
  func submit(
    operation: ShaarBookmarkOperation,
    arguments: Data,
    completion: @escaping @MainActor (Result<Data, Error>) -> Void
  )
}

/// Routes bookmark calls through the Shaar transport.
@MainActor public final class ShaarBookmarksAdapter {
  private let shaar: any ShaarBookmarksTransport

  public init(shaar: any ShaarBookmarksTransport) {
    self.shaar = shaar
  }

  public func tree(
    completion: @escaping @MainActor (Result<[String: Any], Error>) -> Void
  ) {
    call(.tree, arguments: [:]) { result in
      completion(
        result.flatMap { data in
          do {
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Self.hasSupportedSchemaVersion(payload),
              payload["bar"] is [String: Any], payload["other"] is [String: Any]
            else { throw ShaarBookmarksAdapterError.invalidTree }
            return .success(payload)
          } catch { return .failure(error) }
        })
    }
  }

  /// Interactive edits deliberately use one operation per ABI request. Import
  /// sequencing stays with BrowserLibraryModel until batch rollback is proven.
  public func apply(
    _ operation: [String: Any],
    completion: @escaping @MainActor (Result<Void, Error>) -> Void
  ) {
    call(.apply, arguments: ["ops": [operation]]) { result in
      completion(
        result.flatMap { data in
          do {
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Self.hasSupportedSchemaVersion(payload),
              !Self.isJSONBoolean(payload["applied"]),
              !Self.isJSONBoolean(payload["skipped"]),
              (payload["applied"] as? Int) == 1,
              (payload["skipped"] as? Int) == 0,
              (payload["invalid"] as? [Any])?.isEmpty == true
            else { throw ShaarBookmarksAdapterError.mutationNotConfirmed }
            return .success(())
          } catch { return .failure(error) }
        })
    }
  }

  public func watch(
    enabled: Bool,
    completion: @escaping @MainActor (Result<Void, Error>) -> Void
  ) {
    call(.watch, arguments: ["enabled": enabled]) { result in
      completion(
        result.flatMap { data in
          do {
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Self.hasSupportedSchemaVersion(payload),
              Self.isJSONBoolean(payload["watching"]),
              (payload["watching"] as? Bool) == enabled
            else { throw ShaarBookmarksAdapterError.watchNotConfirmed }
            return .success(())
          } catch { return .failure(error) }
        })
    }
  }

  private func call(
    _ operation: ShaarBookmarkOperation,
    arguments: [String: Any],
    completion: @escaping @MainActor (Result<Data, Error>) -> Void
  ) {
    var envelope = arguments
    envelope["schemaVersion"] = 1
    do {
      let bytes = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
      shaar.submit(operation: operation, arguments: bytes, completion: completion)
    } catch {
      completion(.failure(error))
    }
  }

  private static func isJSONBoolean(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
  }

  private static func hasSupportedSchemaVersion(_ payload: [String: Any]) -> Bool {
    guard let version = payload["schemaVersion"] as? NSNumber,
      !isJSONBoolean(version)
    else { return false }
    return Int(exactly: version.doubleValue) == 1
  }
}

public enum ShaarBookmarksAdapterError: Error, Equatable, Sendable {
  case invalidTree
  case mutationNotConfirmed
  case watchNotConfirmed
}

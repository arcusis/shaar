// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Tracks accepted C ABI requests until their single reply or engine shutdown.
/// The opaque C context is the globally unique request ID, so duplicate and
/// late callbacks can safely be ignored without dereferencing freed memory.
final class ShaarABIReplyBox: @unchecked Sendable {
  let requestID: UInt64
  private let lock = NSLock()
  private var resolveBody: ((Result<Data, ShaarEngineError>) -> Void)?

  init(requestID: UInt64, resolve: @escaping (Result<Data, ShaarEngineError>) -> Void) {
    self.requestID = requestID
    resolveBody = resolve
  }

  func resolve(_ result: Result<Data, ShaarEngineError>) {
    lock.lock()
    let body = resolveBody
    resolveBody = nil
    lock.unlock()
    body?(result)
  }

  func cancel() {
    lock.lock()
    resolveBody = nil
    lock.unlock()
  }
}

final class ShaarABIReplyRegistry: @unchecked Sendable {
  static let shared = ShaarABIReplyRegistry()
  private let lock = NSLock()
  private var nextID: UInt64 = 0x7300_0000_0000_0001
  private var pending: [UInt64: ShaarABIReplyBox] = [:]

  func make(
    resolve: @escaping (Result<Data, ShaarEngineError>) -> Void
  ) -> ShaarABIReplyBox {
    lock.lock()
    defer { lock.unlock() }
    let id = nextID
    nextID &+= 1
    if nextID == 0 { nextID = 0x7300_0000_0000_0001 }
    let box = ShaarABIReplyBox(requestID: id, resolve: resolve)
    pending[id] = box
    return box
  }

  func context(for box: ShaarABIReplyBox) -> UnsafeMutableRawPointer {
    UnsafeMutableRawPointer(bitPattern: UInt(box.requestID))!
  }

  func resolve(context: UnsafeMutableRawPointer?, _ result: Result<Data, ShaarEngineError>) {
    guard let context else { return }
    let id = UInt64(UInt(bitPattern: context))
    lock.lock()
    let box = pending.removeValue(forKey: id)
    lock.unlock()
    box?.resolve(result)
  }

  func discard(context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let id = UInt64(UInt(bitPattern: context))
    lock.lock()
    let box = pending.removeValue(forKey: id)
    lock.unlock()
    // Drop the completion without calling it; submit itself reports rejection.
    box?.cancel()
  }

  func resolve(
    context: UnsafeMutableRawPointer?,
    using body: (UInt64) -> Result<Data, ShaarEngineError>
  ) {
    guard let context else { return }
    let id = UInt64(UInt(bitPattern: context))
    lock.lock()
    let box = pending.removeValue(forKey: id)
    lock.unlock()
    guard let box else { return }
    box.resolve(body(id))
  }

  func shutdown() {
    lock.lock()
    let boxes = Array(pending.values)
    pending.removeAll()
    lock.unlock()
    let error = ShaarEngineError.status(.shuttingDown, platformCode: 0, message: "engine is shutting down")
    boxes.forEach { $0.resolve(.failure(error)) }
  }
}

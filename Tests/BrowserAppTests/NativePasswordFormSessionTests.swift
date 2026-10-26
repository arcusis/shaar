import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@MainActor private final class FakePasswordBackend: NativePasswordFormBackend {
  var requests: [(UUID, PasswordFillBinding, (PasswordFillContext?) -> Void)] = []
  var fills: [(PasswordFillContext, (Bool) -> Void)] = []
  var canceled: [UUID] = []
  var available = true
  func request(
    id: UUID, binding: PasswordFillBinding, completion: @escaping (PasswordFillContext?) -> Void
  ) {
    if available { requests.append((id, binding, completion)) } else { completion(nil) }
  }
  func fill(
    context: PasswordFillContext, username: String, password: String,
    completion: @escaping (Bool) -> Void
  ) {
    fills.append((context, completion))
  }
  func cancel(id: UUID) { canceled.append(id) }
  func reply(_ index: Int = 0, binding: PasswordFillBinding? = nil) -> PasswordFillContext {
    let (id, original, completion) = requests[index]
    let context = PasswordFillContext(
      requestID: id, binding: binding ?? original,
      origin: PasswordFillOrigin("https://example.com")!)
    completion(context)
    return context
  }
}

@Suite @MainActor struct NativePasswordFormSessionTests {
  private func binding() -> PasswordFillBinding {
    PasswordFillBinding(windowID: UUID(), profileID: UUID(), tabID: UUID())
  }

  @Test func unavailableCompletesOnce() {
    let backend = FakePasswordBackend()
    backend.available = false
    let bound = binding()
    let session = NativePasswordFormSession(backend: backend) { bound }
    var replies = 0
    session.request { result in
      replies += 1
      #expect(result == nil)
    }
    session.cancel()
    #expect(replies == 1)
  }

  @Test func rejectsForeignAndChangingOwnerDuringRequest() {
    for change in 0..<4 {
      let backend = FakePasswordBackend()
      var current = binding()
      let original = current
      let session = NativePasswordFormSession(backend: backend) { current }
      var replies: [PasswordFillContext?] = []
      session.request { replies.append($0) }
      switch change {
      case 0:
        current = PasswordFillBinding(
          windowID: UUID(), profileID: original.profileID, tabID: original.tabID)
      case 1:
        current = PasswordFillBinding(
          windowID: original.windowID, profileID: UUID(), tabID: original.tabID)
      case 2:
        current = PasswordFillBinding(
          windowID: original.windowID, profileID: original.profileID, tabID: UUID())
      default: break
      }
      let forged = change == 3 ? binding() : nil
      _ = backend.reply(binding: forged)
      #expect(replies.count == 1 && replies[0] == nil)
      #expect(backend.canceled.count == 1)
    }
  }

  @Test func expiryReplayAndLateFillAreFenced() {
    let backend = FakePasswordBackend()
    let bound = binding()
    var clock: TimeInterval = 0
    let session = NativePasswordFormSession(
      backend: backend, now: { clock }, currentBinding: { bound })
    var result: PasswordFillContext?
    session.request { result = $0 }
    let context = backend.reply()
    #expect(result == context)
    var fills: [Bool] = []
    session.fill(context: context, username: "synthetic", password: "synthetic") {
      fills.append($0)
    }
    session.fill(context: context, username: "synthetic", password: "synthetic") {
      fills.append($0)
    }
    #expect(fills == [false])
    clock = 31
    backend.fills[0].1(true)
    backend.fills[0].1(true)
    #expect(fills == [false, false])
    #expect(backend.fills.count == 1)
  }

  @Test func cancelFencesPendingAndLateCallbacks() {
    let backend = FakePasswordBackend()
    let bound = binding()
    let session = NativePasswordFormSession(backend: backend) { bound }
    var requestReplies = 0
    session.request { _ in requestReplies += 1 }
    session.cancel()
    _ = backend.reply()
    #expect(requestReplies == 1)
    var context: PasswordFillContext?
    session.request { context = $0 }
    _ = backend.reply(1)
    var fillReplies: [Bool] = []
    session.fill(context: context!, username: "synthetic", password: "synthetic") {
      fillReplies.append($0)
    }
    session.cancel()
    backend.fills[0].1(true)
    #expect(fillReplies == [false])
  }

  @Test func changedBindingFencesFillReply() {
    let backend = FakePasswordBackend()
    var bound = binding()
    let session = NativePasswordFormSession(backend: backend) { bound }
    var context: PasswordFillContext?
    session.request { context = $0 }
    _ = backend.reply()
    var result: Bool?
    session.fill(context: context!, username: "synthetic", password: "synthetic") { result = $0 }
    bound = binding()
    backend.fills[0].1(true)
    #expect(result == false)
  }
  @Test func destructionAndDuplicateRequestRepliesCompleteOnce() {
    let backend = FakePasswordBackend()
    let bound = binding()
    var session: NativePasswordFormSession? = NativePasswordFormSession(backend: backend) { bound }
    var replies: [PasswordFillContext?] = []
    session?.request { replies.append($0) }
    _ = backend.reply()
    _ = backend.reply()
    #expect(replies.count == 1)
    let context = replies[0]!
    var fills: [Bool] = []
    session?.fill(context: context, username: "synthetic", password: "synthetic") {
      fills.append($0)
    }
    session = nil
    backend.fills[0].1(true)
    #expect(fills == [false])
  }

  @Test func staleOwnerAndExpiredRequestCannotBeRevived() {
    let backend = FakePasswordBackend()
    var current = binding()
    let initial = current
    var clock: TimeInterval = 0
    let session = NativePasswordFormSession(
      backend: backend, now: { clock }, currentBinding: { current })
    var first: PasswordFillContext?
    session.request { first = $0 }
    _ = backend.reply()
    current = binding()
    session.bindingDidChange()
    current = initial
    var result: Bool?
    session.fill(context: first!, username: "synthetic", password: "synthetic") { result = $0 }
    #expect(result == false)
    var replies = 0
    session.request { context in
      replies += 1
      #expect(context == nil)
    }
    clock = 30
    _ = backend.reply(1)
    _ = backend.reply(1)
    #expect(replies == 1)
    #expect(backend.fills.isEmpty)
  }

  @Test func reentrantCancellationDoesNotLoseSuccessor() {
    let backend = FakePasswordBackend()
    let bound = binding()
    let session = NativePasswordFormSession(backend: backend) { bound }
    var oldReplies = 0
    var supersededReplies = 0
    var successor: PasswordFillContext?
    session.request { _ in
      oldReplies += 1
      session.request { successor = $0 }
    }
    session.request { value in
      supersededReplies += 1
      #expect(value == nil)
    }
    #expect(oldReplies == 1)
    #expect(supersededReplies == 1)
    #expect(backend.requests.count == 2)
    let context = backend.reply(1)
    #expect(successor == context)
  }

  @Test func reentrantBindingCancellationPreventsFill() {
    let backend = FakePasswordBackend()
    let bound = binding()
    var cancelOnBinding = false
    var session: NativePasswordFormSession!
    session = NativePasswordFormSession(backend: backend) {
      if cancelOnBinding {
        cancelOnBinding = false
        session.cancel()
      }
      return bound
    }
    var context: PasswordFillContext?
    session.request { context = $0 }
    _ = backend.reply()
    cancelOnBinding = true
    var result: Bool?
    session.fill(context: context!, username: "synthetic", password: "synthetic") { result = $0 }
    #expect(result == false)
    #expect(backend.fills.isEmpty)
    #expect(backend.canceled.count == 1)
  }

  @Test func reentrantFillReplyPreservesSuccessor() {
    let backend = FakePasswordBackend()
    let bound = binding()
    var replaceOnBinding = false
    var successor: PasswordFillContext?
    var session: NativePasswordFormSession!
    session = NativePasswordFormSession(backend: backend) {
      if replaceOnBinding {
        replaceOnBinding = false
        session.request { successor = $0 }
      }
      return bound
    }
    var context: PasswordFillContext?
    session.request { context = $0 }
    _ = backend.reply()
    var results: [Bool] = []
    session.fill(context: context!, username: "synthetic", password: "synthetic") {
      results.append($0)
    }
    replaceOnBinding = true
    backend.fills[0].1(true)
    #expect(results == [false])
    let next = backend.reply(1)
    #expect(successor == next)
    #expect(results == [false])
  }

  @Test func rejectsUnboundedAndUnrepresentableDeadlines() {
    for (lifetime, clock) in [
      (31.0, 0.0), (Double.infinity, 0.0), (1.0, Double.greatestFiniteMagnitude),
    ] {
      let backend = FakePasswordBackend()
      let bound = binding()
      let session = NativePasswordFormSession(
        backend: backend, lifetime: lifetime, now: { clock }, currentBinding: { bound })
      var replies = 0
      session.request {
        replies += 1
        #expect($0 == nil)
      }
      #expect(replies == 1)
      #expect(backend.requests.isEmpty)
    }
  }
}

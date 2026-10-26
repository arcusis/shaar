import BrowserCore
import ChromiumBridge
import Foundation

@MainActor
protocol NativePasswordFormBackend: AnyObject {
  func request(
    id: UUID, binding: PasswordFillBinding, completion: @escaping (PasswordFillContext?) -> Void)
  func fill(
    context: PasswordFillContext, username: String, password: String,
    completion: @escaping (Bool) -> Void)
  func cancel(id: UUID)
}

/// Thin adapter; the runtime owns native handles and validates its actual window and tab.
@MainActor
final class ChromiumPasswordFormBackend: NativePasswordFormBackend {
  private let runtime: ARCChromiumRuntime
  private var contexts: [UUID: ARCPasswordFillContext] = [:]

  init(runtime: ARCChromiumRuntime) { self.runtime = runtime }

  func request(
    id: UUID, binding: PasswordFillBinding, completion: @escaping (PasswordFillContext?) -> Void
  ) {
    runtime.requestPasswordFill(
      forRequestID: id.uuidString, windowID: binding.windowID.uuidString,
      profileID: binding.profileID.uuidString, tabID: binding.tabID.uuidString
    ) { [weak self] native in
      guard let self else {
        completion(nil)
        return
      }
      guard let native, let requestID = UUID(uuidString: native.requestID),
        let windowID = UUID(uuidString: native.windowID),
        let profileID = UUID(uuidString: native.profileID),
        let tabID = UUID(uuidString: native.tabID), let origin = PasswordFillOrigin(native.origin)
      else {
        self.runtime.cancelPasswordRequestID(id.uuidString)
        completion(nil)
        return
      }
      var documentURL: PasswordFillDocumentURL?
      if let value = native.documentURL {
        guard let validated = PasswordFillDocumentURL(value, origin: origin) else {
          self.runtime.cancelPasswordRequestID(id.uuidString)
          completion(nil)
          return
        }
        documentURL = validated
      }
      let context = PasswordFillContext(
        requestID: requestID,
        binding: PasswordFillBinding(windowID: windowID, profileID: profileID, tabID: tabID),
        origin: origin, documentURL: documentURL)
      guard requestID == id, context.binding == binding else {
        self.runtime.cancelPasswordRequestID(id.uuidString)
        completion(nil)
        return
      }
      self.contexts[id] = native
      completion(context)
    }
  }

  func fill(
    context: PasswordFillContext, username: String, password: String,
    completion: @escaping (Bool) -> Void
  ) {
    guard let native = contexts.removeValue(forKey: context.requestID) else {
      completion(false)
      return
    }
    runtime.fillPasswordContext(native, username: username, password: password) { result in
      completion(result)
    }
  }

  func cancel(id: UUID) {
    contexts.removeValue(forKey: id)
    runtime.cancelPasswordRequestID(id.uuidString)
  }
}

/// Owns publication rights for one native request. Cancellation fences completion;
/// renderer work already delivered by the engine cannot be undone.
@MainActor
final class NativePasswordFormSession {
  private final class Pending {
    let id: UUID
    let binding: PasswordFillBinding
    let deadline: TimeInterval
    var lease: PasswordFillLease?
    var requestReply: ((PasswordFillContext?) -> Void)?
    var fillReply: ((Bool) -> Void)?
    init(
      id: UUID, binding: PasswordFillBinding, deadline: TimeInterval,
      reply: @escaping (PasswordFillContext?) -> Void
    ) {
      self.id = id
      self.binding = binding
      self.deadline = deadline
      self.requestReply = reply
    }
  }

  private let backend: NativePasswordFormBackend
  private let currentBinding: () -> PasswordFillBinding?
  private let now: () -> TimeInterval
  private let lifetime: TimeInterval
  private var pending: Pending?
  private var generation = UUID()

  init(
    backend: NativePasswordFormBackend, lifetime: TimeInterval = 30,
    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    currentBinding: @escaping () -> PasswordFillBinding?
  ) {
    self.backend = backend
    self.lifetime = lifetime
    self.now = now
    self.currentBinding = currentBinding
  }

  isolated deinit {
    cancel()
  }

  func request(completion: @escaping (PasswordFillContext?) -> Void) {
    let attempt = UUID()
    generation = attempt
    cancelPending()
    guard generation == attempt else {
      completion(nil)
      return
    }
    let binding = currentBinding()
    let start = now()
    let deadline = start + lifetime
    guard generation == attempt, let binding, lifetime.isFinite, lifetime > 0, lifetime <= 30,
      start.isFinite, deadline.isFinite, deadline > start
    else {
      completion(nil)
      return
    }
    let item = Pending(id: UUID(), binding: binding, deadline: deadline, reply: completion)
    pending = item
    Task { @MainActor [weak self, weak item] in
      try? await Task.sleep(for: .seconds(self?.lifetime ?? 0))
      guard let self, let item, self.pending === item else { return }
      self.cancel()
    }
    backend.request(id: item.id, binding: binding) { [weak self, weak item] context in
      guard let self, let item else { return }
      guard self.pending === item, item.requestReply != nil else { return }
      let binding = self.currentBinding()
      let currentTime = self.now()
      guard self.pending === item, item.requestReply != nil else { return }
      guard let context, context.requestID == item.id, context.binding == item.binding,
        context.documentURL.map({ $0.origin == context.origin }) ?? true,
        binding == item.binding, currentTime.isFinite, currentTime < item.deadline
      else {
        self.cancel()
        return
      }
      item.lease = PasswordFillLease(context: context, deadline: item.deadline)
      let reply = item.requestReply
      item.requestReply = nil
      reply?(context)
    }
  }

  func fill(
    context: PasswordFillContext, username: String, password: String,
    completion: @escaping (Bool) -> Void
  ) {
    guard let item = pending, let lease = item.lease else {
      completion(false)
      return
    }
    let binding = currentBinding()
    let currentTime = now()
    guard pending === item else {
      completion(false)
      return
    }
    guard lease.consume(context: context, binding: binding, now: currentTime) else {
      if item.fillReply == nil, lease.context == context { cancel() }
      completion(false)
      return
    }
    item.fillReply = completion
    backend.fill(context: context, username: username, password: password) {
      [weak self, weak item] success in
      guard let self, let item, self.pending === item else { return }
      let binding = self.currentBinding()
      let currentTime = self.now()
      guard self.pending === item else { return }
      let valid = binding == item.binding && currentTime.isFinite && currentTime < item.deadline
      self.pending = nil
      let reply = item.fillReply
      item.fillReply = nil
      reply?(success && valid)
    }
  }

  /// Invoke when host selection or window ownership changes.
  func bindingDidChange() {
    guard let item = pending else { return }
    let binding = currentBinding()
    if pending === item, binding != item.binding { cancel() }
  }

  func cancel() {
    generation = UUID()
    cancelPending()
  }

  private func cancelPending() {
    guard let item = pending else { return }
    pending = nil
    let requestReply = item.requestReply
    let fillReply = item.fillReply
    item.requestReply = nil
    item.fillReply = nil
    backend.cancel(id: item.id)
    requestReply?(nil)
    fillReply?(false)
  }
}

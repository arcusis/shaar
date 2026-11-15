// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Observation
import SwiftUI

@MainActor
protocol InspectorToastCancellation {
  func cancel()
}

@MainActor
protocol InspectorToastScheduling {
  func schedule(_ clear: @escaping @MainActor () -> Void) -> any InspectorToastCancellation
}

@MainActor
private struct InspectorToastTask: InspectorToastCancellation {
  let task: Task<Void, Never>

  func cancel() { task.cancel() }
}

@MainActor
struct SystemInspectorToastScheduler: InspectorToastScheduling {
  func schedule(_ clear: @escaping @MainActor () -> Void) -> any InspectorToastCancellation {
    let task = Task {
      do { try await Task.sleep(for: .seconds(2.5)) } catch { return }
      guard !Task.isCancelled else { return }
      clear()
    }
    return InspectorToastTask(task: task)
  }
}

@MainActor @Observable final class InspectorPresentation {
  var collapsedSections: Set<String> = ["Code:Layout", "Code:Element overrides", "Code:Tools"]
  var codeSections: Set<String> = ["Code:Styles"]
  var copyMenuOpen = false
  private(set) var toast: String?
  @ObservationIgnored private let toastScheduler: any InspectorToastScheduling
  @ObservationIgnored private var toastTimeout: (any InspectorToastCancellation)?
  @ObservationIgnored private var toastGeneration = 0

  init(toastScheduler: any InspectorToastScheduling = SystemInspectorToastScheduler()) {
    self.toastScheduler = toastScheduler
  }

  func copied(_ subject: String) {
    toastGeneration += 1
    let generation = toastGeneration
    toastTimeout?.cancel()
    toast = InspectorL10n.format(
      "Copied %@ to clipboard", arguments: [.string(InspectorL10n.string(subject))])
    toastTimeout = toastScheduler.schedule { [weak self] in
      guard let self, self.toastGeneration == generation else { return }
      self.toast = nil
      self.toastTimeout = nil
    }
  }

  func dismiss() {
    copyMenuOpen = false
    toastGeneration += 1
    toastTimeout?.cancel()
    toastTimeout = nil
    toast = nil
  }
}

@MainActor final class InspectorLayoutSnapshot {
  var panelSize = CGSize.zero
  var contentFrame = CGRect.zero
  var breadcrumbFrames: [Int: CGRect] = [:]
  var tabFrames: [String: CGRect] = [:]
  var copyMenuFrame = CGRect.zero
}

extension EnvironmentValues {
  @Entry var inspectorPresentation: InspectorPresentation? = nil
  @Entry var inspectorSectionScope: String = "Design"
}

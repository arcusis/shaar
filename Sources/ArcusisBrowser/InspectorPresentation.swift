// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Observation
import SwiftUI

@MainActor @Observable final class InspectorPresentation {
  var collapsedSections: Set<String> = ["Code:Layout", "Code:Element overrides", "Code:Tools"]
  var codeSections: Set<String> = ["Code:Styles"]
  var copyMenuOpen = false
  private(set) var toast: String?
  @ObservationIgnored private var toastTask: Task<Void, Never>?

  func copied(_ subject: String) {
    toastTask?.cancel()
    toast = InspectorL10n.format(
      "Copied %@ to clipboard", arguments: [.string(InspectorL10n.string(subject))])
    toastTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(2.5)) } catch { return }
      self?.toast = nil
    }
  }

  func dismiss() {
    copyMenuOpen = false
    toastTask?.cancel()
    toastTask = nil
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

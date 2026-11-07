// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct InspectorLayoutSection: View {
  @Bindable var model: InspectorLayoutModel
  let generation: Int

  var body: some View {
    InspectorSection(InspectorL10n.string("Flex and grid"), id: "Flex and grid") {
      VStack(alignment: .leading, spacing: 6) {
        if model.containers.isEmpty {
          Text(InspectorL10n.string("No flex or grid containers"))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        } else {
          ForEach(model.containers) { container in
            row(container)
          }
          if model.containers.contains(where: { $0.kind == .grid }) {
            option("Line numbers", isOn: optionBinding(\.showLineNumbers, model.setLineNumbers))
            option("Track sizes", isOn: optionBinding(\.showTrackSizes, model.setTrackSizes))
            option("Area names", isOn: optionBinding(\.showAreaNames, model.setAreaNames))
          }
        }
        if let failure = model.failure {
          Text(failure)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .task(id: generation) {
      while !Task.isCancelled {
        await model.refresh()
        try? await Task.sleep(for: .milliseconds(700))
      }
    }
  }

  private func row(_ container: InspectorLayoutContainer) -> some View {
    Toggle(isOn: containerBinding(container.key)) {
      HStack(spacing: 6) {
        Text(container.title).lineLimit(1)
        Spacer(minLength: 4)
        Text(kindName(container.kind)).foregroundStyle(.secondary)
      }
    }
    .toggleStyle(.checkbox)
    .font(.system(size: 11))
  }

  private func option(_ title: String, isOn: Binding<Bool>) -> some View {
    Toggle(InspectorL10n.string(title), isOn: isOn)
      .toggleStyle(.checkbox)
      .font(.system(size: 11))
  }

  private func kindName(_ kind: InspectorLayoutContainer.Kind) -> String {
    switch kind {
    case .grid:
      return InspectorL10n.string("grid")
    case .flex:
      return InspectorL10n.string("flex")
    }
  }

  private func containerBinding(_ key: String) -> Binding<Bool> {
    Binding(
      get: { model.isOn(key) },
      set: { _ in Task { await model.toggle(key) } })
  }

  private func optionBinding(
    _ path: KeyPath<InspectorLayoutModel, Bool>,
    _ update: @escaping (Bool) async -> Void
  ) -> Binding<Bool> {
    Binding(
      get: { model[keyPath: path] },
      set: { value in Task { await update(value) } })
  }
}

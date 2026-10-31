// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct ProfileNameEditor: View {
  let title: String
  let initialName: String
  let onCancel: () -> Void
  let onSave: (String) -> Bool
  @State private var name: String
  @State private var errorMessage: String?
  @FocusState private var isNameFocused: Bool

  init(
    title: String, initialName: String, onCancel: @escaping () -> Void,
    onSave: @escaping (String) -> Bool
  ) {
    self.title = title
    self.initialName = initialName
    self.onCancel = onCancel
    self.onSave = onSave
    _name = State(initialValue: initialName)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(title).font(.headline)
      TextField("Profile name", text: $name)
        .accessibilityLabel("Profile name")
        .focused($isNameFocused)
        .onChange(of: name) { errorMessage = nil }
      if let errorMessage {
        Text(errorMessage).font(.callout).foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button(initialName.isEmpty ? "Create" : "Save") {
          errorMessage = onSave(name) ? nil : "Profile could not be saved."
        }
        .keyboardShortcut(.defaultAction)
        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 360)
    .onAppear { isNameFocused = true }
  }
}

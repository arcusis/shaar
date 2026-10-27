import SwiftUI

/// Presents the immutable original site, not the current redirected page.
struct NativePasswordSaveConsentView: View {
  @Bindable var coordinator: NativePasswordSaveCoordinator

  var body: some View {
    if let presentation = coordinator.presentation {
      VStack(alignment: .leading, spacing: 8) {
        Text("Save password?").font(.headline)
        Text(presentation.originalSite).textSelection(.enabled)
        Text("Vault: \(presentation.accountLabel)").font(.caption)
        if presentation.allowCreate {
          Button("Save new login") { coordinator.save() }
        }
        if !presentation.choices.isEmpty {
          Text("Or update an existing login:").font(.caption)
          ScrollView {
            LazyVStack(alignment: .leading) {
              ForEach(presentation.choices) { choice in
                Button {
                  coordinator.update(choice.id)
                } label: {
                  VStack(alignment: .leading) {
                    Text(choice.name)
                    if let username = choice.username {
                      Text(username).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Update").font(.caption)
                  }.frame(maxWidth: .infinity, alignment: .leading)
                }
              }
            }
          }.frame(maxHeight: 200)
        }
        Button("Cancel") { coordinator.cancel() }.keyboardShortcut(.cancelAction)
      }
      .padding(12)
      .frame(width: 320)
      .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
      .shadow(radius: 12)
    }
  }
}

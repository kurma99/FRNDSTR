import FRNDSAPI
import SwiftUI

/// Asks what to embed before saving a post to Photos.
struct SaveOptionsSheet: View {
    let post: PostDTO
    let onSave: (SaveOptions) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var options = SaveSettings.defaults
    @State private var remember = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $options.includeCaption) {
                        Label("Include caption", systemImage: "text.quote")
                    }
                    .disabled(post.caption == nil)
                    .accessibilityIdentifier("includeCaptionToggle")

                    Toggle(isOn: $options.includeLocation) {
                        Label {
                            VStack(alignment: .leading) {
                                Text("Include location")
                                if let place = post.location?.placeName {
                                    Text(place).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "location")
                        }
                    }
                    .disabled(post.location == nil)
                    .accessibilityIdentifier("includeLocationToggle")
                } footer: {
                    Text("The caption is written into the file so Apple Photos shows it. The post's date is always included.")
                }

                Section {
                    Toggle("Remember my choice", isOn: $remember)
                        .accessibilityIdentifier("rememberToggle")
                } footer: {
                    Text("You can change this later in Settings.")
                }
            }
            .navigationTitle(post.media.count == 1 ? "Save to Photos" : "Save \(post.media.count) items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var chosen = options
                        if post.caption == nil { chosen.includeCaption = false }
                        if post.location == nil { chosen.includeLocation = false }
                        // Remember the toggles as the user set them, not the per-post fallbacks.
                        if remember { SaveSettings.remember(options) }
                        dismiss()
                        onSave(chosen)
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("confirmSaveButton")
                }
            }
        }
        .presentationDetents([.medium])
        // Half-height glass sheets let bright photos bleed through; keep text readable.
        .presentationBackground(.thickMaterial)
    }
}

import FriendsterAPI
import SwiftUI

/// The moment as the sender arranged it in the editing step.
struct EditedMoment {
    var back: UIImage
    var front: UIImage
    var layout: MomentLayout
    var caption: String
}

/// Editing choices, kept by the flow so going back and forth never loses them.
struct MomentDraft {
    var layout: MomentLayout
    var mirrorFront: Bool
    var mirrorBack = false
    var caption = ""

    /// Starts from the defaults in Settings.
    static func fromSettings() -> MomentDraft {
        let defaults = UserDefaults.standard
        let corner = defaults.string(forKey: MomentSettings.insetCornerKey).flatMap(MomentLayout.Corner.init(rawValue:))
        return MomentDraft(layout: MomentLayout(insetCorner: corner ?? .topLeading),
                           mirrorFront: defaults.bool(forKey: MomentSettings.mirrorSelfieKey))
    }

    func apply(to original: (back: UIImage, front: UIImage)) -> EditedMoment {
        EditedMoment(back: mirrorBack ? original.back.withHorizontallyFlippedOrientation() : original.back,
                     front: mirrorFront ? original.front.withHorizontallyFlippedOrientation() : original.front,
                     layout: layout, caption: caption)
    }
}

/// Step 2 after capturing: position the small photo, switch or flip the photos, add a caption.
struct MomentEditView: View {
    let original: (back: UIImage, front: UIImage)
    @Binding var draft: MomentDraft
    var onRetake: () -> Void
    var onNext: () -> Void

    @FocusState private var captionFocused: Bool

    private var edited: EditedMoment { draft.apply(to: original) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    DualPhotoView(source: .local(back: edited.back, front: edited.front), layout: $draft.layout)
                        .padding(.horizontal, 24)
                        .accessibilityIdentifier("momentEditor")

                    Text("Drag the small photo to move it, pinch to resize it. Tap it to switch.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    GlassEffectContainer(spacing: 10) {
                        HStack(spacing: 10) {
                            Button {
                                withAnimation(.snappy) { draft.layout.swapped.toggle() }
                            } label: {
                                Label("Switch", systemImage: "arrow.left.arrow.right")
                            }
                            .accessibilityIdentifier("switchPhotosButton")
                            Button {
                                withAnimation(.snappy) { draft.mirrorFront.toggle() }
                            } label: {
                                Label("Flip selfie", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                            }
                            .accessibilityIdentifier("flipSelfieButton")
                            Button {
                                withAnimation(.snappy) { draft.mirrorBack.toggle() }
                            } label: {
                                Label("Flip back", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right.fill")
                            }
                            .accessibilityIdentifier("flipBackButton")
                        }
                        .buttonStyle(.glass)
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline)
                    }

                    TextField("Add a caption…", text: $draft.caption, axis: .vertical)
                        .lineLimit(1...3)
                        .focused($captionFocused)
                        .padding(14)
                        .background(.fill.quaternary, in: .rect(cornerRadius: 18))
                        .padding(.horizontal, 20)
                        .onChange(of: draft.caption) { _, text in
                            if text.count > API.Moments.maxCaptionLength { draft.caption = String(text.prefix(API.Moments.maxCaptionLength)) }
                        }
                        .accessibilityIdentifier("momentCaptionField")
                }
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Edit moment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Retake", systemImage: "arrow.counterclockwise", action: onRetake)
                        .accessibilityIdentifier("retakeButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Next") {
                        captionFocused = false
                        onNext()
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("editNextButton")
                }
            }
        }
    }
}

import FriendsterAPI
import PhotosUI
import SwiftUI

/// "New post" sheet: pick up to 10 photos/videos, add a caption, share.
struct ComposeView: View {
    var onPosted: (PostDTO) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model = ComposeModel()
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var confirmDiscard = false
    @FocusState private var captionFocused: Bool

    private let cameraAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)

    var body: some View {
        NavigationStack {
            form
                .navigationTitle("New post")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .overlay {
                    if model.isUploading { uploadingOverlay }
                }
                .onChange(of: pickerItems) { _, selection in
                    model.syncPickerSelection(selection)
                }
                .fullScreenCover(isPresented: $showCamera) {
                    CameraPicker { result in model.add(result) }
                        .ignoresSafeArea()
                }
                .alert("Couldn't share", isPresented: showsError) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(model.errorMessage ?? "")
                }
                .interactiveDismissDisabled(model.isUploading || !model.items.isEmpty)
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                mediaSection
                sourceButtons
                captionField
                locationRow
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private var captionField: some View {
        TextField("Write a caption…", text: $model.caption, axis: .vertical)
            .lineLimit(3...10)
            .focused($captionFocused)
            .padding(16)
            .background(.fill.quaternary, in: .rect(cornerRadius: 20))
            .accessibilityIdentifier("captionField")

        if model.caption.count > API.Limits.maxCaptionLength - 200 {
            Text("\(model.caption.count)/\(API.Limits.maxCaptionLength)")
                .font(.caption)
                .foregroundStyle(model.caption.count > API.Limits.maxCaptionLength ? .red : .secondary)
        }
    }

    /// Opt-in location, shown on the post and used when saving to Photos.
    private var locationRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.and.ellipse")
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Add location")
                    .font(.body)
                switch model.locationState {
                case .off:
                    EmptyView()
                case .locating:
                    Text("Finding location…").font(.footnote).foregroundStyle(.secondary)
                case let .found(location):
                    Text(location.placeName ?? String(format: "%.4f, %.4f", location.latitude, location.longitude))
                        .font(.footnote).foregroundStyle(.secondary)
                case let .failed(message):
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            }
            Spacer()
            Toggle("Add location", isOn: Binding(
                get: { model.locationState != .off },
                set: { enabled in Task { await model.setLocationEnabled(enabled) } }
            ))
            .labelsHidden()
            .accessibilityIdentifier("locationToggle")
        }
        .padding(16)
        .background(.fill.quaternary, in: .rect(cornerRadius: 20))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", systemImage: "xmark", role: .cancel) {
                if model.hasContent {
                    confirmDiscard = true
                } else {
                    dismiss()
                }
            }
            .disabled(model.isUploading)
            .confirmationDialog("Discard this post?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) {
                    model.cleanUpFiles()
                    dismiss()
                }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Share", action: share)
                .fontWeight(.semibold)
                .disabled(!model.canShare)
                .accessibilityIdentifier("shareButton")
        }
    }

    private var showsError: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    // MARK: Sections

    @ViewBuilder
    private var mediaSection: some View {
        if model.items.isEmpty {
            PhotosPicker(selection: $pickerItems, maxSelectionCount: API.Limits.maxMediaPerPost,
                         selectionBehavior: .ordered, matching: .any(of: [.images, .videos]),
                         preferredItemEncoding: .current) {
                VStack(spacing: 12) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.accent)
                    Text("Choose photos or videos")
                        .font(.headline)
                    Text("Up to \(API.Limits.maxMediaPerPost) per post")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 320)
                .background(.fill.quaternary, in: .rect(cornerRadius: 28))
                .contentShape(.rect(cornerRadius: 28))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("emptyPicker")
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(model.items) { item in
                        ItemPreview(item: item) {
                            withAnimation(.snappy) {
                                if let pickerItem = item.pickerItem {
                                    pickerItems.removeAll { $0 == pickerItem }
                                }
                                model.remove(item.id)
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    private var sourceButtons: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                PhotosPicker(selection: $pickerItems, maxSelectionCount: API.Limits.maxMediaPerPost,
                             selectionBehavior: .ordered, matching: .any(of: [.images, .videos]),
                             preferredItemEncoding: .current) {
                    Label("Library", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("libraryButton")

                Button {
                    showCamera = true
                } label: {
                    Label("Camera", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(!cameraAvailable || model.remainingSlots == 0)
            }
            .controlSize(.large)
        }
    }

    private var uploadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView(value: model.uploadProgress)
                    .progressViewStyle(.circular)
                    .controlSize(.large)
                    .tint(Theme.accent)
                Text("Sharing…")
                    .font(.headline)
            }
            .padding(28)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
        }
        .transition(.opacity)
    }

    private func share() {
        captionFocused = false
        Task {
            if let post = await model.share(using: app) {
                onPosted(post)
                dismiss()
            }
        }
    }
}

private struct ItemPreview: View {
    let item: ComposeModel.Item
    let onRemove: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 140, height: 175)
            .overlay {
                switch item.state {
                case .preparing:
                    ProgressView()
                case let .ready(media):
                    Image(uiImage: media.preview)
                        .resizable()
                        .scaledToFill()
                        .allowsHitTesting(false)
                case let .failed(message):
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(message)
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.red)
                    .padding(8)
                }
            }
            .background(.fill.quaternary)
            .clipShape(.rect(cornerRadius: 18))
            .overlay(alignment: .bottomLeading) {
                if let duration = item.prepared?.duration {
                    Label(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)), systemImage: "play.fill")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .glassEffect(.regular, in: .capsule)
                        .padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button("Remove", systemImage: "xmark", action: onRemove)
                    .labelStyle(.iconOnly)
                    .font(.caption.weight(.bold))
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .padding(6)
            }
    }
}

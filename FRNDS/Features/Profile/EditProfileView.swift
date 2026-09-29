import FRNDSAPI
import PhotosUI
import SwiftUI

/// Change name and profile photo.
struct EditProfileView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        if let user = app.currentUser {
                            AvatarView(user: user, size: 110)
                                .overlay { if isWorking { ProgressView() } }
                        }
                        HStack(spacing: 10) {
                            PhotosPicker(selection: $photoItem, matching: .images) {
                                Text("Change photo")
                            }
                            .buttonStyle(.glass)
                            .accessibilityIdentifier("changePhotoButton")
                            if app.currentUser?.avatarPath != nil {
                                Button("Remove", role: .destructive, action: removePhoto)
                                    .buttonStyle(.glass)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section("Name") {
                    TextField("Your name", text: $displayName)
                        .textContentType(.name)
                        .accessibilityIdentifier("displayNameField")
                }
            }
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: saveName)
                        .fontWeight(.semibold)
                        .disabled(displayName.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                        .accessibilityIdentifier("saveProfileButton")
                }
            }
            .onAppear { displayName = app.currentUser?.displayName ?? "" }
            .onChange(of: photoItem) { _, item in
                if let item { uploadPhoto(item) }
            }
            .alert("Something went wrong", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func saveName() {
        guard let client = app.client else { return }
        let name = displayName.trimmingCharacters(in: .whitespaces)
        guard name != app.currentUser?.displayName else { return dismiss() }
        run {
            app.updateCurrentUser(try await client.updateProfile(displayName: name))
            dismiss()
        }
    }

    private func uploadPhoto(_ item: PhotosPickerItem) {
        guard let client = app.client else { return }
        run {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw MediaPreparationError.unreadableImage
            }
            let jpeg = try await MediaPreparer.prepareAvatar(data: data)
            app.updateCurrentUser(try await client.uploadAvatar(jpeg: jpeg))
            photoItem = nil
        }
    }

    private func removePhoto() {
        guard let client = app.client else { return }
        run { app.updateCurrentUser(try await client.deleteAvatar()) }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await work()
            } catch {
                app.handle(error)
                errorMessage = error.localizedDescription
            }
        }
    }
}

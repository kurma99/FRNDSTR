import SwiftUI
import UIKit
import UniformTypeIdentifiers
import FrndstrAPI

/// System camera for taking a photo or recording a video.
struct CameraPicker: UIViewControllerRepresentable {
    var onCapture: (ComposeModel.CameraResult) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        picker.videoMaximumDuration = API.Limits.maxVideoSeconds
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL {
                // The picker's file is deleted once we return; keep our own copy.
                let copy = MediaPreparer.temporaryURL(extension: url.pathExtension.isEmpty ? "mov" : url.pathExtension)
                if (try? FileManager.default.copyItem(at: url, to: copy)) != nil {
                    parent.onCapture(.video(copy))
                }
            } else if let image = info[.originalImage] as? UIImage {
                parent.onCapture(.photo(image))
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

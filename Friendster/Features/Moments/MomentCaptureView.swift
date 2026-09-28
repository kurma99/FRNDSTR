import AVFoundation
import PhotosUI
import SwiftUI

/// UIKit view backed by a preview layer; created once so the camera can connect to it during setup.
final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        previewLayer.videoGravity = .resizeAspectFill
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private struct CameraPreview: UIViewRepresentable {
    let view: PreviewUIView
    func makeUIView(context: Context) -> PreviewUIView { view }
    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

/// Full-screen BeReal-style capture: back camera with the front camera inset, one shutter.
/// Without a camera (Simulator) you can pick two photos instead.
struct MomentCaptureView: View {
    var onCaptured: (_ back: UIImage, _ front: UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var camera = DualCamera()
    @State private var backPreview = PreviewUIView()
    @State private var frontPreview = PreviewUIView()
    @State private var mode: DualCamera.Mode?
    @State private var isCapturing = false
    @State private var errorMessage: String?
    @State private var pickerItems: [PhotosPickerItem] = []

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch mode {
            case nil:
                ProgressView().tint(.white)
            case .unavailable?, .denied?:
                unavailableView
            case .multiCam?, .sequential?:
                cameraView
            }
        }
        .overlay(alignment: .topTrailing) {
            Button("Close", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .padding()
                .accessibilityIdentifier("closeCaptureButton")
        }
        .task {
            mode = await camera.configure(backLayer: backPreview.previewLayer, frontLayer: frontPreview.previewLayer)
            if mode == .multiCam || mode == .sequential { camera.start() }
        }
        .onDisappear { camera.stop() }
        .onChange(of: pickerItems) { _, items in
            if items.count == 2 { Task { await loadPicked(items) } }
        }
        .alert("Couldn't take the moment", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var cameraView: some View {
        VStack(spacing: 24) {
            Text(mode == .sequential ? "Hold still – back camera, then front" : "Your moment")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.top, 20)

            CameraPreview(view: backPreview)
                .aspectRatio(3 / 4, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 28))
                .overlay(alignment: .topLeading) {
                    if mode == .multiCam {
                        CameraPreview(view: frontPreview)
                            .frame(width: 118, height: 157)
                            .clipShape(.rect(cornerRadius: 16))
                            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.black, lineWidth: 2) }
                            .padding(14)
                    }
                }
                .padding(.horizontal, 12)

            Button(action: capture) {
                ZStack {
                    Circle().strokeBorder(.white, lineWidth: 5)
                    Circle().fill(.white).padding(10)
                    if isCapturing { ProgressView().tint(.black) }
                }
                .frame(width: 84, height: 84)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .disabled(isCapturing)
            .accessibilityLabel("Take moment")
            .accessibilityIdentifier("shutterButton")

            Spacer(minLength: 0)
        }
    }

    private var unavailableView: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 52))
                .foregroundStyle(.white.opacity(0.8))
            Text(mode == .denied ? "Camera access is off" : "No camera available")
                .font(.title3.bold())
                .foregroundStyle(.white)
            Text(mode == .denied
                 ? "Moments are taken live with both cameras. Allow camera access for Friendster in Settings."
                 : "Moments are taken live with both cameras.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 32)
            if mode == .denied, let settings = URL(string: UIApplication.openSettingsURLString) {
                Link(destination: settings) {
                    Label("Open Settings", systemImage: "gear")
                        .font(.headline)
                        .padding(.horizontal, 8)
                }
                .primaryButtonStyle()
                .controlSize(.large)
            }
            #if targetEnvironment(simulator)
            // Testing only: the Simulator has no camera. Real devices never pick moments from the library.
            PhotosPicker(selection: $pickerItems, maxSelectionCount: 2, selectionBehavior: .ordered, matching: .images) {
                Label("Test: choose 2 photos", systemImage: "photo.on.rectangle")
                    .font(.headline)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .accessibilityIdentifier("pickMomentPhotosButton")
            #endif
        }
    }

    private func capture() {
        isCapturing = true
        Task {
            defer { isCapturing = false }
            do {
                let photos = try await camera.capture()
                camera.stop()
                onCaptured(photos.back, photos.front)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadPicked(_ items: [PhotosPickerItem]) async {
        var images: [UIImage] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                errorMessage = String(localized: "These photos couldn't be loaded.")
                pickerItems = []
                return
            }
            images.append(image)
        }
        onCaptured(images[0], images[1])
    }
}

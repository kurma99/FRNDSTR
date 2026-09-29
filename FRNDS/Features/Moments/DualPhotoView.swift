import FRNDSAPI
import SwiftUI

/// Big photo with the other one inset in a corner (like BeReal).
/// Drag the inset to move it (it snaps to the nearest corner), tap it to switch the photos,
/// and pinch with two fingers to resize it.
struct DualPhotoView: View {
    enum Source: Equatable {
        case remote(back: String, front: String)
        case local(back: UIImage, front: UIImage)
    }

    let source: Source
    @Binding var layout: MomentLayout
    var cornerRadius: CGFloat = 24
    /// Size of the small photo when the layout doesn't set one.
    var insetFraction: CGFloat = 0.3
    var isInteractive = true

    @State private var dragOffset: CGSize = .zero
    /// Live pinch factor, folded into `layout.insetSize` when the pinch ends.
    @State private var pinchScale: CGFloat = 1

    private var baseFraction: CGFloat { layout.insetSize.map { CGFloat($0) } ?? insetFraction }

    private var currentFraction: CGFloat {
        let range = MomentLayout.insetSizeRange
        return min(max(baseFraction * pinchScale, range.lowerBound), range.upperBound)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let inset = CGSize(width: size.width * currentFraction, height: size.width * currentFraction * 4 / 3)
            let origin = Self.origin(of: layout.insetCorner, in: size, inset: inset)

            ZStack(alignment: .topLeading) {
                image(front: layout.swapped)
                    .frame(width: size.width, height: size.height)
                    .clipped()

                image(front: !layout.swapped)
                    .frame(width: inset.width, height: inset.height)
                    .clipShape(.rect(cornerRadius: cornerRadius * 0.55))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius * 0.55).strokeBorder(.black, lineWidth: 2)
                    }
                    .shadow(color: .black.opacity(dragOffset == .zero ? 0 : 0.3), radius: 10)
                    .contentShape(.rect(cornerRadius: cornerRadius * 0.55))
                    .offset(x: origin.x + dragOffset.width, y: origin.y + dragOffset.height)
                    .onTapGesture {
                        guard isInteractive else { return }
                        withAnimation(.snappy) { layout.swapped.toggle() }
                    }
                    .gesture(drag(in: size, inset: inset, origin: origin), isEnabled: isInteractive)
                    .accessibilityAddTraits(isInteractive ? .isButton : [])
                    .accessibilityLabel(isInteractive ? "Switch photos" : "Small photo")
                    .accessibilityHint(isInteractive ? "Drag to move it to another corner. Pinch to resize." : "")
                    .accessibilityAdjustableAction { direction in
                        guard isInteractive else { return }
                        let step = direction == .increment ? 0.05 : -0.05
                        layout.insetSize = MomentLayout(insetSize: Double(baseFraction) + step).insetSize
                    }
            }
            // Two fingers anywhere on the photo resize the small one.
            .simultaneousGesture(pinch, isEnabled: isInteractive)
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .clipShape(.rect(cornerRadius: cornerRadius))
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { pinchScale = $0.magnification }
            .onEnded { _ in
                let fraction = currentFraction
                withAnimation(.snappy) {
                    layout.insetSize = Double(fraction)
                    pinchScale = 1
                }
            }
    }

    private func drag(in size: CGSize, inset: CGSize, origin: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { dragOffset = $0.translation }
            .onEnded { value in
                let center = CGPoint(x: origin.x + value.translation.width + inset.width / 2,
                                     y: origin.y + value.translation.height + inset.height / 2)
                let corner = Self.nearestCorner(to: center, in: size)
                withAnimation(.spring(duration: 0.35, bounce: 0.25)) {
                    layout.insetCorner = corner
                    dragOffset = .zero
                }
            }
    }

    static func origin(of corner: MomentLayout.Corner, in size: CGSize, inset: CGSize) -> CGPoint {
        let margin = size.width * 0.04
        let left = margin, right = size.width - inset.width - margin
        let top = margin, bottom = size.height - inset.height - margin
        switch corner {
        case .topLeading: return CGPoint(x: left, y: top)
        case .topTrailing: return CGPoint(x: right, y: top)
        case .bottomLeading: return CGPoint(x: left, y: bottom)
        case .bottomTrailing: return CGPoint(x: right, y: bottom)
        }
    }

    static func nearestCorner(to point: CGPoint, in size: CGSize) -> MomentLayout.Corner {
        switch (point.x < size.width / 2, point.y < size.height / 2) {
        case (true, true): .topLeading
        case (false, true): .topTrailing
        case (true, false): .bottomLeading
        case (false, false): .bottomTrailing
        }
    }

    @ViewBuilder
    private func image(front: Bool) -> some View {
        switch source {
        case let .remote(back, frontPath):
            RemoteImage(path: front ? frontPath : back)
        case let .local(back, frontImage):
            Image(uiImage: front ? frontImage : back)
                .resizable()
                .scaledToFill()
                .allowsHitTesting(false)
        }
    }
}

/// A viewer that starts with the sender's arrangement; the viewer can rearrange it for themselves.
struct MomentPhotos: View {
    let source: DualPhotoView.Source
    var cornerRadius: CGFloat = 24
    var insetFraction: CGFloat = 0.3
    @State private var layout: MomentLayout

    init(source: DualPhotoView.Source, layout: MomentLayout?, cornerRadius: CGFloat = 24, insetFraction: CGFloat = 0.3) {
        self.source = source
        self.cornerRadius = cornerRadius
        self.insetFraction = insetFraction
        _layout = State(initialValue: layout ?? MomentLayout())
    }

    var body: some View {
        DualPhotoView(source: source, layout: $layout, cornerRadius: cornerRadius, insetFraction: insetFraction)
    }
}

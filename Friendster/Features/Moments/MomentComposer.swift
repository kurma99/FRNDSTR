import FriendsterAPI
import UIKit

/// Image helpers for moments: upload-ready JPEGs and the BeReal-style composite (back + front inset).
nonisolated enum MomentComposer {
    /// Upright, metadata-free JPEG no larger than `maxPixel` on its long edge.
    static func jpeg(_ image: UIImage, maxPixel: CGFloat, quality: CGFloat = 0.85) -> Data {
        let size = scaledSize(image.size, maxPixel: maxPixel)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        // Drawing bakes the orientation in and drops all EXIF/GPS.
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: quality) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 3:4 portrait with one photo inset in a corner, arranged exactly like the in-app editor
    /// (`layout`). Both photos are center-cropped to fill their frames.
    static func composite(back: UIImage, front: UIImage, layout: MomentLayout = MomentLayout(),
                          height: CGFloat = 1600) -> UIImage {
        let size = CGSize(width: (height * 3 / 4).rounded(), height: height)
        let insetWidth = size.width * layout.resolvedInsetSize
        let insetSize = CGSize(width: insetWidth, height: insetWidth * 4 / 3)
        let margin = size.width * 0.04
        let insetOrigin: CGPoint = switch layout.insetCorner {
        case .topLeading: CGPoint(x: margin, y: margin)
        case .topTrailing: CGPoint(x: size.width - insetWidth - margin, y: margin)
        case .bottomLeading: CGPoint(x: margin, y: size.height - insetSize.height - margin)
        case .bottomTrailing: CGPoint(x: size.width - insetWidth - margin, y: size.height - insetSize.height - margin)
        }
        let insetRect = CGRect(origin: insetOrigin, size: insetSize)
        let radius = insetWidth * 0.12
        let (main, small) = layout.swapped ? (front, back) : (back, front)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            main.draw(in: aspectFill(main.size, in: CGRect(origin: .zero, size: size)))
            let path = UIBezierPath(roundedRect: insetRect, cornerRadius: radius)
            context.cgContext.saveGState()
            path.addClip()
            small.draw(in: aspectFill(small.size, in: insetRect))
            context.cgContext.restoreGState()
            UIColor.black.setStroke()
            path.lineWidth = max(2, size.width * 0.004)
            path.stroke()
        }
    }

    /// Rect that fills `bounds` with an image of `size`, centered (overflow is clipped by the caller/canvas).
    static func aspectFill(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = max(bounds.width / size.width, bounds.height / size.height)
        let scaled = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - scaled.width / 2, y: bounds.midY - scaled.height / 2,
                      width: scaled.width, height: scaled.height)
    }

    static func scaledSize(_ size: CGSize, maxPixel: CGFloat) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > maxPixel, longest > 0 else { return CGSize(width: size.width.rounded(), height: size.height.rounded()) }
        let factor = maxPixel / longest
        return CGSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())
    }
}

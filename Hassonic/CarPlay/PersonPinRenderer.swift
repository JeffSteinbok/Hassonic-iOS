import UIKit

/// Renders the circular map pins for the CarPlay people screen: a person's
/// Home Assistant profile picture cropped to a circle inside a ring, or their
/// initials on a solid disc when there's no picture to show.
///
/// CarPlay map annotations take a finished bitmap — no dynamic colours, no
/// auto-layout, and a size the framework dictates via
/// `CPPointOfInterest.pinImageSize` — so everything is baked in here.
enum PersonPinRenderer {
    private static let ringColor = UIColor.white
    private static let shadowColor = UIColor.black.withAlphaComponent(0.35)
    private static let initialsBackground = UIColor(red: 0.16, green: 0.42, blue: 0.85, alpha: 1)

    /// Ring thickness scales with the pin so the selected (larger) pin doesn't
    /// end up with a hairline border.
    private static func ringWidth(for size: CGSize) -> CGFloat {
        max(2, min(size.width, size.height) * 0.08)
    }

    static func pin(avatar: UIImage?, name: String, size: CGSize, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = scale > 0 ? scale : 1
        format.opaque = false

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let ring = ringWidth(for: size)
            // Inset by the full ring width, not half: the stroke is centred on
            // the path, and the shadow needs room outside it too.
            let circle = CGRect(origin: .zero, size: size).insetBy(dx: ring, dy: ring)
            let path = UIBezierPath(ovalIn: circle)

            context.cgContext.saveGState()
            context.cgContext.setShadow(offset: CGSize(width: 0, height: 1), blur: ring, color: shadowColor.cgColor)
            ringColor.setFill()
            path.fill()
            context.cgContext.restoreGState()

            context.cgContext.saveGState()
            path.addClip()
            if let avatar {
                avatar.draw(in: aspectFillRect(for: avatar.size, in: circle))
            } else {
                initialsBackground.setFill()
                context.cgContext.fill(circle)
                draw(initials: initials(for: name), in: circle)
            }
            context.cgContext.restoreGState()

            ringColor.setStroke()
            path.lineWidth = ring
            path.stroke()
        }
    }

    /// First letters of the first two words — "Jamie Sterling" → "JS". Falls
    /// back to a person glyph for names with nothing alphabetic in them.
    static func initials(for name: String) -> String {
        let letters = name
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
            .compactMap { $0.first(where: \.isLetter) }
            .prefix(2)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    /// The rect to draw `imageSize` into so it fills `bounds` without
    /// distortion, overflowing on the longer axis and centred.
    static func aspectFillRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func draw(initials: String, in rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: rect.height * 0.42, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        let text = initials as NSString
        let textSize = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
            withAttributes: attributes
        )
    }
}

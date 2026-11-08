import AppKit

/// The app icon reduced to a menu bar glyph: the shield outlined, with the
/// pointer inside. A template image, so macOS tints it for the menu bar.
enum MenuBarIcon {
    /// Locked: the outline. Unlocked: a filled shield with the pointer cut out.
    @MainActor static let image = make(filled: false)
    @MainActor static let filledImage = make(filled: true)

    /// Same paths as `AppIcon.icon` (a 1024 canvas), scaled to 18 pt.
    private static func make(filled: Bool) -> NSImage {
        let size = CGSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            // The shield spans x 224…800 and y 150…884 on the icon's canvas.
            let scale: CGFloat = 16.5 / 734
            let transform = NSAffineTransform()
            transform.translateX(by: (size.width - 576 * scale) / 2 - 224 * scale,
                                 yBy: (size.height - 734 * scale) / 2 - 150 * scale)
            transform.scale(by: scale)

            let shield = NSBezierPath()
            shield.move(to: CGPoint(x: 512, y: 150))
            shield.line(to: CGPoint(x: 800, y: 250))
            shield.line(to: CGPoint(x: 800, y: 520))
            shield.curve(to: CGPoint(x: 512, y: 884), controlPoint1: CGPoint(x: 800, y: 700),
                         controlPoint2: CGPoint(x: 670, y: 820))
            shield.curve(to: CGPoint(x: 224, y: 520), controlPoint1: CGPoint(x: 354, y: 820),
                         controlPoint2: CGPoint(x: 224, y: 700))
            shield.line(to: CGPoint(x: 224, y: 250))
            shield.close()
            shield.transform(using: transform as AffineTransform)
            shield.lineJoinStyle = .round

            // The pointer: translate(436.9 330.6) scale(0.47) on the canvas.
            let pointer = NSBezierPath()
            let points: [CGPoint] = [(0, 0), (0, 600), (150, 460), (240, 670), (330, 630), (240, 425), (430, 425)]
                .map { CGPoint(x: 436.9 + $0.0 * 0.47, y: 330.6 + $0.1 * 0.47) }
            pointer.move(to: points[0])
            for point in points.dropFirst() { pointer.line(to: point) }
            pointer.close()
            pointer.transform(using: transform as AffineTransform)
            pointer.lineJoinStyle = .round

            NSColor.black.set()
            if filled {
                shield.fill()
                // Knock the pointer out of the fill.
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                pointer.lineWidth = 1.2
                pointer.fill()
                pointer.stroke()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            } else {
                shield.lineWidth = 1.4
                shield.stroke()
                pointer.lineWidth = 0.8
                pointer.fill()
                pointer.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

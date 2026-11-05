import AppKit
import SwiftUI

/// The app's mark: two comets swapping places around a flat coral core.
/// Pure CoreGraphics so the popover, the template status item and the
/// AppIcon renderer (`scripts/render-icon.sh`) draw from one source.
enum LogoArt {
    enum Style {
        /// White arcs and a coral core, for dark backgrounds (the AppIcon).
        case color
        /// Graphite arcs and a coral core, for the app's light surfaces.
        case colorOnLight
        /// One opaque colour, for template images that macOS tints.
        case template
    }

    /// The core's coral, also the interface accent (`Theme.accent`).
    static let coral = CGColor(srgbRed: 0xEA / 255.0, green: 0x7B / 255.0, blue: 0x52 / 255.0, alpha: 1)
    /// The comets on light surfaces: the interface's primary text colour (`Theme.primary`).
    static let graphite = CGColor(srgbRed: 0x1D / 255.0, green: 0x1D / 255.0, blue: 0x1F / 255.0, alpha: 1)

    /// Draws the mark into `rect` of a y-up CoreGraphics context.
    static func draw(in ctx: CGContext, rect: CGRect, style: Style) {
        ctx.saveGState()
        // Design space: unit square, y down.
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: rect.width, y: -rect.height)

        let template = style == .template
        let arcColor: CGColor
        switch style {
        case .color: arcColor = CGColor(gray: 1, alpha: 1)
        case .colorOnLight: arcColor = graphite
        case .template: arcColor = CGColor(gray: 0, alpha: 1)
        }
        if !template {
            // Faint orbit the comets travel on.
            let o = orbitRadius
            ctx.setStrokeColor(style == .color ? CGColor(gray: 1, alpha: 0.10) : CGColor(gray: 0, alpha: 0.10))
            ctx.setLineWidth(0.014)
            ctx.strokeEllipse(in: CGRect(x: 0.5 - o, y: 0.5 - o, width: 2 * o, height: 2 * o))
        }
        for start in [200.0, 20.0] {
            ctx.saveGState()
            // In colour the trail fades in towards the head.
            if !template { ctx.clip(to: CGRect(x: 0, y: 0, width: 1, height: 1), mask: fadeMask(start: start)) }
            ctx.addPath(comet(start: start, template: template))
            ctx.setFillColor(arcColor)
            ctx.fillPath()
            ctx.restoreGState()
        }

        let r = template ? 0.15 : 0.14
        let core = CGRect(x: 0.5 - r, y: 0.5 - r, width: 2 * r, height: 2 * r)
        ctx.setFillColor(template ? arcColor : coral)
        ctx.fillEllipse(in: core)
        ctx.restoreGState()
    }

    static let cometSweep = 140.0
    static let orbitRadius = 0.355

    /// Conic alpha ramp (CoreGraphics has no conic gradient): faint at a
    /// comet's tail, opaque from three quarters of its sweep on.
    private static func fadeMask(start: Double) -> CGImage {
        let n = 256
        var px = [UInt8](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                // The first mask row lands at design y = 1 under the flipped CTM.
                let dx = (Double(x) + 0.5) / Double(n) - 0.5, dy = 0.5 - (Double(y) + 0.5) / Double(n)
                var d = atan2(dy, dx) * 180 / .pi - start
                d = d.truncatingRemainder(dividingBy: 360)
                if d < 0 { d += 360 }
                let t = min(1, d / (cometSweep * 0.75))
                let a = d > cometSweep + 30 ? 1 : 0.12 + 0.88 * t * t * (3 - 2 * t)
                px[y * n + x] = UInt8(a * 255)
            }
        }
        let provider = CGDataProvider(data: Data(px) as CFData)!
        // A grey image, not an image mask: as a clip, white paints and black hides.
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: n,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    /// A comet on the orbit: a trail that thickens clockwise from `start`
    /// degrees into a round head, the account taking its turn.
    static func comet(start: Double, template: Bool) -> CGPath {
        let c = CGPoint(x: 0.5, y: 0.5)
        let radius = orbitRadius
        let sweep = cometSweep
        let head = template ? 0.09 : 0.066
        let tail = template ? 0.025 : 0.0
        let steps = 64

        func point(_ deg: Double, _ r: Double) -> CGPoint {
            let a = deg * .pi / 180
            return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        }
        // Half-width eases from the tail to the head radius.
        func half(_ t: Double) -> Double { tail / 2 + (head - tail / 2) * pow(t, 1.6) }

        let end = start + sweep
        let p = CGMutablePath()
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let pt = point(start + sweep * t, radius + half(t))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        for i in stride(from: steps, through: 0, by: -1) {
            let t = Double(i) / Double(steps)
            p.addLine(to: point(start + sweep * t, radius - half(t)))
        }
        p.closeSubpath()
        let h = point(end, radius)
        p.addEllipse(in: CGRect(x: h.x - head, y: h.y - head, width: 2 * head, height: 2 * head))
        return p
    }

    /// Menu bar glyph that adapts to light and dark menu bars.
    static func templateImage(pointSize: CGFloat = 16) -> NSImage {
        let img = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: ctx, rect: rect, style: .template)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "just swap"
        return img
    }
}

struct LogoMark: View {
    var size: CGFloat

    var body: some View {
        Canvas { ctx, sz in
            ctx.withCGContext { cg in
                // Canvas hands over a y-down context; flip to the y-up one LogoArt expects.
                cg.translateBy(x: 0, y: sz.height)
                cg.scaleBy(x: 1, y: -1)
                LogoArt.draw(in: cg, rect: CGRect(origin: .zero, size: sz), style: .colorOnLight)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("just swap")
    }
}

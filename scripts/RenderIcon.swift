import AppKit

/// Renders the AppIcon set and logo preview sheets from `LogoArt`.
///   RenderIcon <appiconset dir> <preview dir>
@main enum RenderIcon {
    static func main() throws {
        let args = CommandLine.arguments
        let iconSet = URL(fileURLWithPath: args[1])
        let previews = URL(fileURLWithPath: args[2])

        var images: [[String: String]] = []
        for pt in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = pt * scale
                let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
                try write(bitmap(px) { appIcon(in: $0, size: CGFloat(px)) }, to: iconSet.appendingPathComponent(name))
                images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
            }
        }
        let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
        try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
            .write(to: iconSet.appendingPathComponent("Contents.json"))

        try write(bitmap(1024) { appIcon(in: $0, size: 1024) }, to: previews.appendingPathComponent("logo-icon-1024.png"))
        try write(sheet(), to: previews.appendingPathComponent("logo-sizes.png"))
    }

    /// macOS icon grid: an 824 pt rounded square inside 1024 with room for the shadow.
    static func appIcon(in ctx: CGContext, size: CGFloat) {
        let s = size / 1024
        let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let shape = CGPath(roundedRect: body, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
        let rgb = CGColorSpace(name: CGColorSpace.sRGB)!

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(shape)
        ctx.setFillColor(CGColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        // Graphite tile with a small tone shift inside one neutral, and a flat hairline rim.
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        let bg = CGGradient(colorsSpace: rgb, colors: [
            CGColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1),
            CGColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
        ctx.restoreGState()

        // Clipped to the tile, so only the inner half of the stroke shows.
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.addPath(shape)
        ctx.setLineWidth(max(2, 6 * s))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
        ctx.strokePath()
        ctx.restoreGState()

        // The mark fills more of the tile at small sizes so it stays legible.
        let mark = (size <= 32 ? 700 : 600) * s
        LogoArt.draw(in: ctx, rect: CGRect(x: (size - mark) / 2, y: (size - mark) / 2, width: mark, height: mark), style: .color)
    }

    /// Preview: the mark at popover sizes on the (light) popover colour, and the
    /// template on light and dark menu bars, at 2x.
    static func sheet() -> NSBitmapImageRep {
        let scale: CGFloat = 2
        let w: CGFloat = 520, h: CGFloat = 220
        return bitmap(Int(w * scale), Int(h * scale)) { ctx in
            ctx.scaleBy(x: scale, y: scale)
            ctx.setFillColor(CGColor(srgbRed: 0xF6 / 255.0, green: 0xF6 / 255.0, blue: 0xF7 / 255.0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 110, width: w, height: 110))
            var x: CGFloat = 16
            for s in [16.0, 28.0, 36.0, 64.0, 80.0] {
                LogoArt.draw(in: ctx, rect: CGRect(x: x, y: 165 - s / 2, width: s, height: s), style: .colorOnLight)
                x += s + 22
            }
            for (i, dark) in [false, true].enumerated() {
                let band = CGRect(x: 0, y: CGFloat(i) * 55, width: w, height: 55)
                ctx.setFillColor(dark ? CGColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 1)
                                      : CGColor(srgbRed: 0.92, green: 0.92, blue: 0.93, alpha: 1))
                ctx.fill(band)
                var x: CGFloat = 16
                for s in [16.0, 18.0, 22.0, 32.0] {
                    // Template tint as macOS applies it: black or white.
                    let tile = CGRect(x: x, y: band.midY - s / 2, width: s, height: s)
                    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                    LogoArt.draw(in: ctx, rect: tile, style: .template)
                    ctx.setBlendMode(.sourceIn)
                    ctx.setFillColor(dark ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 0.85))
                    ctx.fill(tile)
                    ctx.setBlendMode(.normal)
                    ctx.endTransparencyLayer()
                    x += s + 24
                }
            }
        }
    }

    static func bitmap(_ w: Int, _ h: Int? = nil, draw: (CGContext) -> Void) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h ?? w, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let g = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        g.cgContext.interpolationQuality = .high
        draw(g.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        return rep.retagging(with: .sRGB)!
    }

    static func write(_ rep: NSBitmapImageRep, to url: URL) throws {
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }
}

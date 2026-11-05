import JustSwapCore
import SwiftUI

/// A light instrument panel: one graphite-neutral ramp with dark text, one coral
/// accent (the logo's core) with a darker ink for text, and semantic colours
/// darkened to read on white. The app is light whatever the system appearance.
enum Theme {
    /// One knob for text size: every font is a design size times this,
    /// never below `minFont` so secondary text stays readable.
    static let fontScale: CGFloat = 0.75
    static let minFont: CGFloat = 9

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: max(minFont, size * fontScale), weight: weight, design: design)
    }

    /// Slot numbers, window labels, gauge readings and counters.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        font(size, weight, design: .monospaced)
    }

    /// Times and other figures inside text: tabular digits in the interface face.
    static func figures(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        font(size, weight).monospacedDigit()
    }

    // Spacing, on a 4 pt grid.
    static let popoverWidth: CGFloat = 372
    static let pad: CGFloat = 12
    static let gap: CGFloat = 8
    static let radius: CGFloat = 12
    static let controlRadius: CGFloat = 6
    /// Columns of a usage row: the window label and the right-aligned percentage.
    static let windowLabel: CGFloat = 16
    static let windowValue: CGFloat = 32
    /// The switch: about 1.3 times the cap height of the 13 pt-design type.
    static let switchSize = CGSize(width: 18, height: 10)

    static let scheme = ColorScheme.light

    // Graphite-neutral ramp.
    static let background = Color(hex: 0xF6F6F7)
    static let card = Color(hex: 0xFFFFFF)
    static let raised = Color(hex: 0xEFEFF1)
    static let hairline = Color.black.opacity(0.08)
    static let track = Color.black.opacity(0.08)
    static let primary = Color(hex: 0x1D1D1F)
    static let secondary = Color(hex: 0x6E6E73)
    static let muted = Color(hex: 0x8E8E93)

    /// The logo's coral, for fills (switches, the active dot).
    static let accent = Color(cgColor: LogoArt.coral)
    /// Coral as text or glyph ink: 5.2:1 on white.
    static let accentInk = Color(hex: 0xB84A24)
    // Semantic colours, each at least 5:1 on white.
    static let good = Color(hex: 0x2F7A52)
    static let warn = Color(hex: 0x9A5B00)
    static let bad = Color(hex: 0xC4302B)
    /// Amber for gauge fills, brighter than the `warn` ink.
    static let warnFill = Color(hex: 0xD9952B)

    static func tone(_ t: SlotHealth.Tone) -> Color {
        switch t {
        case .good: return good
        case .warn: return warn
        case .bad: return bad
        case .info, .neutral: return secondary
        }
    }

    /// Gauge fill: neutral, amber within 10 points of the switch line, red when spent.
    static func bar(_ pct: Double, line: Double) -> Color {
        if pct >= 100 { return bad }
        if pct >= line - 10 { return warnFill }
        return muted
    }

    static let quick = Animation.easeOut(duration: 0.15)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

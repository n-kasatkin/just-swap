import JustSwapCore
import SwiftUI

struct Card<Content: View>: View {
    var surface: Color = Theme.card
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) { content }
            .padding(Theme.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }
}

struct SectionHeader: View {
    var title: String
    var accessory: String?
    var accessoryHelp: String = ""
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Text(title)
                .font(Theme.font(13, .medium))
                .foregroundStyle(Theme.primary)
            Spacer()
            if let accessory {
                Button { action?() } label: {
                    Image(systemName: accessory)
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(accessoryHelp)
            }
        }
    }
}

/// A header with a chevron and a muted "n/m" counter that folds its content.
struct CollapsibleSection<Content: View>: View {
    var title: String
    var count: Int
    var total: Int
    @Binding var expanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(Theme.font(10, .medium))
                        .foregroundStyle(Theme.muted)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                    Text(title)
                        .font(Theme.font(12, .medium))
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                    Text("\(count)/\(total)")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { content }
        }
    }
}

/// A fuel gauge. The thin full-height tick is the autoswitch line, drawn on
/// every bar and nowhere else; `pace` is a short muted notch under the track
/// where usage should be by now. `hasReading` false means the window has no value yet.
struct UsageBar: View {
    var pct: Double
    var color: Color
    var line: Double
    var pace: Double?
    var dimmed = false
    var hasReading = true

    private static let height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = { (v: Double) in w * min(max(v, 0), 100) / 100 }
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color.opacity(dimmed ? 0.45 : 1))
                    .frame(width: max(Self.height, x(pct)))
                if let pace {
                    // Overlaps the track's lower edge by 1 pt and hangs 3 pt below it.
                    Rectangle()
                        .fill(Theme.secondary)
                        .frame(width: 2, height: 4)
                        .offset(x: x(pace) - 1, y: Self.height / 2 + 1)
                }
                Rectangle()
                    .fill(Theme.primary.opacity(0.75))
                    .frame(width: 1, height: Self.height + 4)
                    .offset(x: x(line) - 0.5)
            }
            .frame(height: Self.height + 4)
            .animation(Theme.quick, value: color)
        }
        .frame(height: Self.height + 4)
        .accessibilityElement()
        .accessibilityLabel("\(hasReading ? Format.percent(pct) : "no reading"), switch at \(Format.percent(line))")
    }
}

/// 24 h of 5h usage for the active slot: one neutral line on a baseline.
struct Sparkline: View {
    var values: [Double]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h - 0.5))
                    p.addLine(to: CGPoint(x: w, y: h - 0.5))
                }
                .stroke(Theme.hairline, lineWidth: 1)
                if values.count > 1 {
                    let step = w / CGFloat(values.count - 1)
                    let pts = values.enumerated().map { i, v in
                        CGPoint(x: CGFloat(i) * step, y: h - 1 - (h - 2) * CGFloat(min(max(v, 0), 100) / 100))
                    }
                    Path { p in
                        p.move(to: pts[0])
                        pts.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(Theme.muted, style: StrokeStyle(lineWidth: 1, lineJoin: .round))
                }
            }
        }
        .frame(height: 12)
    }
}

/// A status: dot and text. Fine states stay quiet; warnings and errors get a faint tag.
struct StatusTag: View {
    var text: String
    var tone: SlotHealth.Tone

    var body: some View {
        let color = Theme.tone(tone)
        let loud = tone == .warn || tone == .bad
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(Theme.font(11, .medium)).lineLimit(1)
        }
        .foregroundStyle(loud ? color : Theme.secondary)
        .padding(.horizontal, loud ? 6 : 0)
        .padding(.vertical, 2)
        .background(loud ? color.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .fixedSize()
    }
}

/// Icon, title, grey description and a trailing control, as one card.
struct ToggleCard<Trailing: View>: View {
    var icon: String
    var title: String
    var description: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        Card {
            HStack(alignment: .center, spacing: Theme.pad) {
                Image(systemName: icon)
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.font(13, .medium)).foregroundStyle(Theme.primary)
                    Text(description)
                        .font(Theme.font(11))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.gap)
                trailing
            }
        }
    }
}

struct FooterButton: View {
    var title: String
    var icon: String
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(Theme.font(12))
                Text(title).font(Theme.font(12, .medium))
            }
            .foregroundStyle(hover ? Theme.primary : Theme.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(hover ? Theme.raised : Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Theme.quick, value: hover)
    }
}

/// A quiet bordered button inside cards.
struct ChipButton: View {
    var title: String
    var icon: String?
    var tone: Color?
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ChipLabel(title: title, icon: icon, tone: tone, hover: hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Theme.quick, value: hover)
    }
}

/// The look of a chip, for buttons and menus alike.
struct ChipLabel: View {
    var title: String
    var icon: String?
    var tone: Color?
    var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(Theme.font(10)) }
            if !title.isEmpty { Text(title).font(Theme.font(11, .medium)).lineLimit(1) }
        }
        .foregroundStyle(tone ?? (hover ? Theme.primary : Theme.secondary))
        .opacity(enabled ? 1 : 0.45)
        .padding(.horizontal, Theme.gap)
        .frame(height: 20)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

struct EmptyState: View {
    var icon: String
    var text: String

    var body: some View {
        Card {
            HStack(spacing: Theme.gap) {
                Image(systemName: icon).font(Theme.font(12)).foregroundStyle(Theme.muted).frame(width: 16)
                Text(text).font(Theme.font(12)).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension View {
    /// The app's switch: sized to about 1.3 times the cap height of the
    /// compact type, coral when on.
    func systemSwitch() -> some View {
        toggleStyle(MiniSwitchStyle()).labelsHidden()
    }
}

/// A switch drawn in SwiftUI at the size of the compact type: a track with a
/// knob, coral when on, grey when off. The stock control scaled down is a
/// platform view whose transform feeds back into window layout.
struct MiniSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        let size = Theme.switchSize
        let knob = size.height - 2
        Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? Theme.accent : Theme.track.opacity(1.6))
                Circle().fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5)
                    .padding(1)
            }
            .frame(width: size.width, height: size.height)
            .opacity(enabled ? 1 : 0.45)
            .animation(Theme.quick, value: on)
            .contentShape(Rectangle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

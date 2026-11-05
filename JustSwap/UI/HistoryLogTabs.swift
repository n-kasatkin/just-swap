import AppKit
import JustSwapCore
import SwiftUI

struct HistoryTab: View {
    @Bindable var model: AppModel
    @State private var showRecent = true
    @State private var showOlder = false

    var body: some View {
        let all = model.history
        let recent = Array(all.prefix(12))
        let older = Array(all.dropFirst(12))
        VStack(alignment: .leading, spacing: Theme.pad) {
            SectionHeader(title: "Switch history", accessory: "arrow.clockwise", accessoryHelp: "Reload") { model.reloadLog() }
            if all.isEmpty { EmptyState(icon: "clock", text: "No switches in the log yet") }
            if !recent.isEmpty {
                CollapsibleSection(title: "Recent", count: recent.count, total: all.count, expanded: $showRecent) {
                    rows(recent)
                }
            }
            if !older.isEmpty {
                CollapsibleSection(title: "Older", count: older.count, total: all.count, expanded: $showOlder) {
                    rows(older)
                }
            }
        }
    }

    private func rows(_ items: [SwitchRecord]) -> some View {
        Card {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, r in
                if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                HStack(spacing: Theme.gap) {
                    Image(systemName: r.trigger == nil ? "hand.tap" : "arrow.triangle.2.circlepath")
                        .font(Theme.font(11))
                        .foregroundStyle(r.trigger == nil ? Theme.muted : Theme.secondary)
                        .frame(width: 16)
                    Text(model.label(forSlot: r.from)).font(Theme.font(12)).foregroundStyle(Theme.secondary).lineLimit(1)
                    Image(systemName: "arrow.right").font(Theme.font(9)).foregroundStyle(Theme.muted)
                    Text(model.label(forSlot: r.to)).font(Theme.font(12, .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let t = r.trigger {
                        Text(t).font(Theme.mono(10)).foregroundStyle(Theme.muted)
                    }
                    Text(Format.clock(r.date)).font(Theme.figures(11)).foregroundStyle(Theme.secondary)
                }
            }
        }
    }
}

struct LogTab: View {
    @Bindable var model: AppModel
    @State private var infoOnly = false

    var body: some View {
        let lines = model.logLines.filter { !infoOnly || $0.level != "DEBUG" && !$0.message.hasPrefix("usage ") }
        VStack(alignment: .leading, spacing: Theme.pad) {
            SectionHeader(title: "claude-swap.log", accessory: "arrow.up.forward.square", accessoryHelp: "Open in the default editor") {
                NSWorkspace.shared.open(SwapLog.logURL)
            }
            ToggleCard(icon: "line.3.horizontal.decrease", title: "Hide usage lines",
                       description: "Keep switches, warnings and errors only") {
                Toggle("", isOn: $infoOnly).systemSwitch()
            }
            if lines.isEmpty { EmptyState(icon: "doc.text", text: "The log is empty") }
            Card {
                ForEach(lines.suffix(60).reversed()) { line in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: Theme.gap) {
                            if let d = line.date {
                                Text(Format.clock(d, seconds: true)).font(Theme.figures(10))
                                    .foregroundStyle(Theme.muted)
                            }
                            if !line.level.isEmpty && line.level != "INFO" {
                                Text(line.level).font(Theme.mono(9, .medium)).foregroundStyle(levelColor(line.level))
                            }
                        }
                        Text(model.redacted(line.message))
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func levelColor(_ level: String) -> Color {
        switch level {
        case "ERROR", "CRITICAL": return Theme.bad
        case "WARNING": return Theme.warn
        default: return Theme.muted
        }
    }
}

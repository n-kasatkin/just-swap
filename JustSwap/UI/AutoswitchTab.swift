import JustSwapCore
import SwiftUI

/// Engine state, the on/off switch, the strategy with what it does, every
/// other `autoswitch.*` key from the schema, and the engine's recent events.
struct AutoswitchTab: View {
    @Bindable var model: AppModel
    @State private var showControls = true
    @State private var showEvents = true

    var body: some View {
        let keys = SettingsLayout.autoswitch(model.settings).filter { $0.key != StrategyCard.key }
        VStack(alignment: .leading, spacing: Theme.pad) {
            LiveStateCard(model: model)
            if let err = model.configError { ErrorBanner(text: err) }
            CollapsibleSection(title: "Controls", count: activeControls(keys), total: keys.count + 2, expanded: $showControls) {
                ToggleCard(icon: "arrow.triangle.2.circlepath", title: "Auto-switch",
                           description: model.autoswitchAvailable
                               ? "Moves to another slot before the active one hits its limit"
                               : "Off for this run (--no-autoswitch)") {
                    Toggle("", isOn: Binding(get: { model.autoswitchAvailable && model.autoEnabled },
                                             set: { model.autoEnabled = $0 }))
                        .systemSwitch()
                        .disabled(!model.autoswitchAvailable)
                }
                StrategyCard(model: model)
                ForEach(keys) { SettingRow(model: model, setting: $0) }
            }
            CollapsibleSection(title: "Recent events", count: min(model.autoEvents.count, 8), total: model.autoEvents.count,
                               expanded: $showEvents) {
                if model.autoEvents.isEmpty {
                    EmptyState(icon: "tray", text: "No engine events in this session")
                } else {
                    Card {
                        ForEach(model.autoEvents.prefix(8)) { item in
                            HStack(alignment: .firstTextBaseline, spacing: Theme.gap) {
                                Image(systemName: item.icon).font(Theme.font(11))
                                    .foregroundStyle(item.tone == .warn || item.tone == .bad ? Theme.tone(item.tone) : Theme.muted)
                                    .frame(width: 16)
                                Text(model.redacted(item.text)).font(Theme.font(11)).lineLimit(2)
                                Spacer(minLength: 4)
                                Text(Format.clock(item.date)).font(Theme.figures(10))
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
            }
        }
        .task { if model.settings.isEmpty { await model.loadConfig() } }
    }

    private func activeControls(_ keys: [ConfigSetting]) -> Int {
        (model.autoEnabled && model.autoswitchAvailable ? 1 : 0)
            + (model.setting(StrategyCard.key)?.isSet == true ? 1 : 0)
            + keys.filter(\.isSet).count
    }
}

/// The strategy picker, what the chosen strategy does, and an info popover
/// describing every choice and how tiers and per-account lines act on them.
struct StrategyCard: View {
    static let key = "autoswitch.strategy"
    @Bindable var model: AppModel
    @State private var showInfo = false

    var body: some View {
        let s = model.setting(Self.key)
        let current = s?.value.stringValue ?? s?.default?.stringValue ?? "best"
        Card {
            HStack(alignment: .center, spacing: Theme.gap) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(Theme.font(15)).foregroundStyle(Theme.secondary).frame(width: 16)
                Text("Strategy").font(Theme.font(13, .medium))
                Button { showInfo.toggle() } label: {
                    Image(systemName: "info.circle").font(Theme.font(12)).foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                .help("What each strategy does")
                .accessibilityLabel("What each strategy does")
                .popover(isPresented: $showInfo, arrowEdge: .bottom) { StrategyInfoView(current: current) }
                Spacer(minLength: Theme.gap)
                ChoicePicker(model: model, key: Self.key) { StrategyInfo.entry($0)?.title ?? $0 }
                if s?.isSet == true {
                    Button { Task { await model.unsetConfig(Self.key) } } label: {
                        Image(systemName: "arrow.uturn.backward").font(Theme.font(11))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Reset to default")
                }
            }
            if let text = StrategyInfo.summary(current) {
                Text(text).font(Theme.font(11)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("\(Self.key) · \(current)").font(Theme.mono(10)).foregroundStyle(Theme.muted)
        }
    }
}

struct StrategyInfoView: View {
    var current: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            ForEach(StrategyInfo.entries, id: \.name) { e in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(e.title).font(Theme.font(13, .medium))
                        Text(e.name).font(Theme.mono(10)).foregroundStyle(Theme.muted)
                        if e.name == current {
                            Text("current").font(Theme.font(10, .medium)).foregroundStyle(Theme.accentInk)
                        }
                    }
                    Text("\(e.leaves) \(e.picks)").font(Theme.font(11)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text(StrategyInfo.interplay).font(Theme.font(11)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.pad)
        .frame(width: 320)
        .background(Theme.card)
        .foregroundStyle(Theme.primary)
        .preferredColorScheme(Theme.scheme)
    }
}

struct LiveStateCard: View {
    @Bindable var model: AppModel

    var body: some View {
        Card {
            HStack {
                Text("Engine").font(Theme.font(13, .medium))
                Spacer()
                StatusTag(text: stateText, tone: stateTone)
            }
            if let poll = model.lastPoll, let n = poll.active?.number {
                let wins = poll.windowsPct?[String(n)] ?? [:]
                let line = poll.line(for: "5h", configuredWeekly: nil, fallback: model.fiveHourLine())
                HStack(spacing: 4) {
                    Text("Active").font(Theme.font(11)).foregroundStyle(Theme.secondary)
                    Text(model.label(forSlot: n)).font(Theme.font(11, .medium))
                    Spacer()
                    Text("Switch at \(Format.percent(line))").font(Theme.font(11)).foregroundStyle(Theme.secondary)
                }
                ForEach(["5h", "7d"], id: \.self) { w in
                    if let pct = wins[w] {
                        let wl = poll.line(for: w, configuredWeekly: model.number("autoswitch.weeklyThreshold"),
                                           fallback: model.fiveHourLine())
                        HStack(spacing: Theme.gap) {
                            Text(w).font(Theme.mono(11)).foregroundStyle(Theme.secondary)
                                .frame(width: Theme.windowLabel, alignment: .leading)
                            UsageBar(pct: pct, color: Theme.bar(pct, line: wl), line: wl)
                            Text(Format.percent(pct)).font(Theme.mono(12, .medium))
                                .foregroundStyle(pct >= 100 ? Theme.bad : Theme.primary)
                                .frame(width: Theme.windowValue, alignment: .trailing)
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: Theme.pad + 4) {
                Stat(title: "Last poll", value: model.lastPoll?.ts.flatMap(ISODate.parse).map { Format.clock($0, seconds: true) } ?? "—")
                Stat(title: "Next poll", value: nextPoll)
                if let ns = model.lastNoSwitch?.reason {
                    Stat(title: "Last decision", value: ns)
                }
            }
        }
    }

    private var nextPoll: String {
        guard let until = model.lastSleep?.until.flatMap(ISODate.parse) else { return "—" }
        return until > Date() ? "in \(Format.countdown(to: until))" : Format.clock(until, seconds: true)
    }

    private var stateText: String {
        switch model.autoState {
        case .stopped: return model.autoswitchAvailable ? "Off" : "Disabled"
        case .running: return model.lastSleep != nil ? "Watching" : "Starting"
        case .restarting: return "Restarting"
        case .blocked: return "Other instance"
        case .failed: return "Failed"
        }
    }

    private var stateTone: SlotHealth.Tone {
        switch model.autoState {
        case .running: return .good
        case .restarting: return .warn
        case .failed, .blocked: return .bad
        case .stopped: return .neutral
        }
    }
}

struct ChoicePicker: View {
    @Bindable var model: AppModel
    var key: String
    var label: (String) -> String = { $0 }

    var body: some View {
        let s = model.setting(key)
        let current = s?.value.stringValue ?? ""
        let choices = s?.choices ?? [current].filter { !$0.isEmpty }
        Menu {
            ForEach(choices, id: \.self) { c in
                Button(label(c)) { Task { await model.setConfig(key, c) } }
            }
        } label: {
            HStack(spacing: 4) {
                Text(current.isEmpty ? "—" : label(current)).font(Theme.font(12, .medium))
                Image(systemName: "chevron.up.chevron.down").font(Theme.font(9, .medium)).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, Theme.gap)
            .frame(height: 20)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(choices.count < 2)
    }
}

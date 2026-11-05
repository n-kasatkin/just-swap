import JustSwapCore
import SwiftUI

/// The in-popover settings page: app switches, the status item, and every
/// `cswap config` key outside `autoswitch.*` (those live on the Autoswitch
/// tab), rendered from the core's schema (kind, bounds, choices, help).
struct SettingsPage: View {
    @Bindable var model: AppModel
    @AppStorage(MenuBarPrefs.logo) private var showLogo = true
    @AppStorage(MenuBarPrefs.account) private var showAccount = false
    @AppStorage(MenuBarPrefs.organization) private var showOrganization = false
    @AppStorage(MenuBarPrefs.fiveHour) private var showFiveHour = false
    @AppStorage(MenuBarPrefs.sevenDay) private var showSevenDay = false
    @AppStorage(MenuBarPrefs.hidden) private var iconHidden = false
    @AppStorage(MenuBarPrefs.separator) private var separator = TitleSeparator.standard
    @AppStorage(MenuBarPrefs.customSeparator) private var customSeparator = ""
    @AppStorage(AppPrefs.ignoreDisabled) private var ignoreDisabled = false
    @AppStorage(AppPrefs.showLogTab) private var showLogTab = false
    @State private var expanded: Set<String> = ["app", "menubar"]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.pad) {
            if let err = model.configError { ErrorBanner(text: err) }

            CollapsibleSection(title: "App", count: appSetCount, total: 3, expanded: binding("app")) {
                ToggleCard(icon: "power", title: "Launch at login", description: "Start the menu bar app when you log in") {
                    Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                        .systemSwitch()
                }
                ToggleCard(icon: "eye.slash", title: "Ignore disabled", description: "Refresh skips disabled accounts") {
                    Toggle("", isOn: $ignoreDisabled).systemSwitch()
                }
                ToggleCard(icon: "text.alignleft", title: "Show log tab", description: "The tail of claude-swap.log as a fourth tab") {
                    Toggle("", isOn: $showLogTab).systemSwitch()
                }
            }

            CollapsibleSection(title: "Menu bar", count: menuBarSetCount, total: 6, expanded: binding("menubar")) {
                ToggleCard(icon: "circle.dotted.circle", title: "Show logo",
                           description: "The app mark. Comes back on its own when nothing else is shown.") {
                    Toggle("", isOn: $showLogo).systemSwitch()
                }
                ToggleCard(icon: "person.crop.circle", title: "Show account name",
                           description: "Alias or email name of the active slot") {
                    Toggle("", isOn: $showAccount).systemSwitch()
                }
                ToggleCard(icon: "building.2", title: "Show organization name",
                           description: "Organization of the active slot, when it has one") {
                    Toggle("", isOn: $showOrganization).systemSwitch()
                }
                ToggleCard(icon: "clock", title: "Show 5h %", description: "Usage of the active slot's 5-hour window") {
                    Toggle("", isOn: $showFiveHour).systemSwitch()
                }
                ToggleCard(icon: "calendar", title: "Show 7d %", description: "Usage of the active slot's 7-day window") {
                    Toggle("", isOn: $showSevenDay).systemSwitch()
                }
                ToggleCard(icon: "textformat", title: "Separator",
                           description: "Between the name, organization and percentages") {
                    separatorControl
                }
                ToggleCard(icon: "menubar.dock.rectangle", title: "Hide menu bar icon",
                           description: "Removes the icon; the app and autoswitch keep running. Open just swap again from Applications or Spotlight to get this window back.") {
                    Toggle("", isOn: $iconHidden).systemSwitch()
                }
            }

            ForEach(SettingsLayout.generalSections(model.settings), id: \.section) { group in
                CollapsibleSection(title: group.section.prefix(1).uppercased() + group.section.dropFirst(),
                                   count: group.settings.filter(\.isSet).count, total: group.settings.count,
                                   expanded: binding(group.section)) {
                    ForEach(group.settings) { SettingRow(model: model, setting: $0) }
                }
            }
            if model.settings.isEmpty && model.configError == nil {
                EmptyState(icon: "hourglass", text: "Loading settings…")
            }
            Text(aboutLine).font(Theme.figures(10)).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .task { await model.loadConfig() }
    }

    /// A preset, or Custom with a field of up to `TitleSeparator.customMaxLength` characters.
    private var separatorControl: some View {
        HStack(spacing: 4) {
            if separator == TitleSeparator.customTag {
                TextField(TitleSeparator.standard, text: $customSeparator)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.font(12))
                    .frame(width: 36)
                    .onChange(of: customSeparator) { _, v in
                        if v.count > TitleSeparator.customMaxLength {
                            customSeparator = String(v.prefix(TitleSeparator.customMaxLength))
                        }
                    }
                    .accessibilityLabel("Custom separator")
            }
            Picker("", selection: Binding(
                get: { TitleSeparator.presets.contains(separator) || separator == TitleSeparator.customTag
                    ? separator : TitleSeparator.standard },
                set: { separator = $0 }
            )) {
                ForEach(TitleSeparator.presets, id: \.self) { p in
                    Text(p == " " ? "a b (space)" : "a\(p)b").tag(p)
                }
                Divider()
                Text("Custom…").tag(TitleSeparator.customTag)
            }
            .labelsHidden().fixedSize()
            .controlSize(.small)
            .accessibilityLabel("Separator")
        }
    }

    private var appSetCount: Int {
        [model.launchAtLogin, ignoreDisabled, showLogTab].filter { $0 }.count
    }

    private var menuBarSetCount: Int {
        [showLogo, showAccount, showOrganization, showFiveHour, showSevenDay, iconHidden].filter { $0 }.count
    }

    private var aboutLine: String {
        let app = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        var parts = ["just swap \(app)"]
        if let v = model.coreVersion { parts.append(v) }
        if let c = model.coreCommit { parts.append("core \(c.prefix(10))") }
        return parts.joined(separator: " · ")
    }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(key) }, set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } })
    }
}

struct SettingRow: View {
    @Bindable var model: AppModel
    let setting: ConfigSetting
    @State private var text = ""
    @FocusState private var focused: Bool
    /// The value last sent, so Return followed by focus loss writes once.
    @State private var committed: String?

    var body: some View {
        Card {
            HStack(alignment: .center, spacing: Theme.gap) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(setting.name).font(Theme.font(13, .medium))
                        if setting.isLocked { Image(systemName: "lock").font(Theme.font(10)).foregroundStyle(Theme.muted) }
                    }
                    if let help = setting.help, !help.isEmpty {
                        Text(Self.caption(help)).font(Theme.font(11)).foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(caption).font(Theme.mono(10)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                control
                if setting.isSet && !setting.isLocked {
                    Button {
                        Task { await model.unsetConfig(setting.key) }
                    } label: {
                        Image(systemName: "arrow.uturn.backward").font(Theme.font(11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.muted)
                    .help("Reset to default")
                }
            }
        }
        .onAppear { text = setting.value.cliValue ?? "" }
        .onChange(of: setting.value) { _, v in
            text = v.cliValue ?? ""
            committed = nil
        }
    }

    /// The core's one-sentence help reads as a caption: no trailing period.
    static func caption(_ help: String) -> String {
        let t = help.trimmingCharacters(in: .whitespaces)
        guard t.hasSuffix("."), !t.dropLast().contains(". ") else { return t }
        return String(t.dropLast())
    }

    private var caption: String {
        var parts = [setting.key]
        if let d = setting.default { parts.append("default \(d)") }
        if let lo = setting.min, let hi = setting.max {
            parts.append("\(JSONScalar.number(lo))–\(JSONScalar.number(hi))")
        }
        if setting.isLocked { parts.append("kept on: setup-token slots need it") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var control: some View {
        switch setting.effectiveKind {
        case "bool":
            Toggle("", isOn: Binding(
                get: { setting.isLocked || setting.value.boolValue == true },
                set: { v in Task { await model.setConfig(setting.key, v ? "true" : "false") } }
            ))
            .systemSwitch()
            .disabled(setting.isLocked)
        case "choice":
            Picker("", selection: Binding(
                get: { setting.value.stringValue ?? "" },
                set: { v in Task { await model.setConfig(setting.key, v) } }
            )) {
                ForEach(setting.choices ?? [setting.value.stringValue ?? ""], id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().fixedSize()
            .font(Theme.font(12))
        default:
            TextField(setting.value == .null ? "unset" : "", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(Theme.font(12).monospacedDigit())
                .frame(width: setting.effectiveKind == "string" ? 100 : 56)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, now in if !now { commit() } }
        }
    }

    private func commit() {
        let v = text.trimmingCharacters(in: .whitespaces)
        guard v != committed else { return }
        committed = v
        if v.isEmpty {
            if setting.isSet { Task { await model.unsetConfig(setting.key) } }
        } else if v != setting.value.cliValue {
            Task { await model.setConfig(setting.key, v) }
        }
    }
}

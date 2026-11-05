import AppKit
import JustSwapCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A row dragged within the account list; declared in Info.plist. Only
    /// this type is accepted on a row, so dropped text never reorders.
    static let justSwapAccount = UTType(exportedAs: "dev.actionhook.justswap.account")
}

/// The one editable account list: every account in slot order, one compact
/// row each, opened in place for its details and actions; rows reorder by
/// drag and drop. The header holds Add account and the list tools.
struct AccountsTab: View {
    @Bindable var model: AppModel
    /// Rows and their state follow the account, not the slot number.
    @State private var expanded: Set<AccountKey> = []
    @State private var launchExpandDone = false
    @State private var dragSource: AccountKey?
    @State private var dropTarget: AccountKey?
    @State private var addOpen: Bool

    init(model: AppModel) {
        self.model = model
        _addOpen = State(initialValue: model.options.addMenu)
    }

    var body: some View {
        let rows = model.accounts.sorted { $0.number < $1.number }
        VStack(alignment: .leading, spacing: Theme.gap) {
            HStack(spacing: Theme.gap) {
                Text("Accounts").font(Theme.font(13, .medium))
                if model.listBusy { ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12) }
                Spacer()
                AddAccountButton(open: $addOpen, disabled: model.listBusy)
                ListToolsMenu(model: model)
            }
            if addOpen { AddAccountMenu(model: model, open: $addOpen) }
            if let err = model.pageError { ErrorBanner(text: err) }
            if let note = model.notice {
                Text(note).font(Theme.font(11)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let err = model.listError, rows.isEmpty {
                ErrorBanner(text: err)
            } else if rows.isEmpty {
                EmptyState(icon: model.loadedAt == nil ? "hourglass" : "person.crop.circle.badge.plus",
                           text: model.loadedAt == nil ? "Loading accounts…" : "No accounts yet: use Add account")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.key) { i, row in
                        let key = row.key
                        // The dragged row lands above the target when it moves up, below when it moves down.
                        let movesUp = (dragSource.flatMap { s in rows.firstIndex { $0.key == s } } ?? i) > i
                        if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                        AccountRowView(model: model, row: row, expanded: Binding(
                            get: { expanded.contains(key) },
                            set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } }
                        ), onDragStart: { dragSource = key })
                        .overlay(alignment: movesUp ? .top : .bottom) {
                            if dropTarget == key, dragSource != key, !model.listBusy {
                                Rectangle().fill(Theme.accent).frame(height: 2)
                            }
                        }
                        .onDrop(of: [.justSwapAccount], isTargeted: Binding(
                            get: { dropTarget == key },
                            set: { on in if on { dropTarget = key } else if dropTarget == key { dropTarget = nil } }
                        )) { _ in
                            // Only a drag that started in this list: the source is known here.
                            defer { dragSource = nil; dropTarget = nil }
                            guard let source = dragSource, source != key, !model.listBusy else { return false }
                            Task { await model.reorder(moving: source, onto: key) }
                            return true
                        }
                    }
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
                Text("Drag a row onto another to move it there")
                    .font(Theme.font(10)).foregroundStyle(Theme.muted)
            }
        }
        .onChange(of: rows.map(\.key), initial: true) { _, _ in expandFromLaunchOption(rows) }
    }

    /// `--expand <slot>` opens that slot's account once the list has loaded.
    private func expandFromLaunchOption(_ rows: [AccountRow]) {
        guard !launchExpandDone, let n = model.options.expandedSlot,
              let row = rows.first(where: { $0.number == n }) else { return }
        expanded.insert(row.key)
        launchExpandDone = true
    }
}

/// The Add account button; its two choices open inline under the header.
struct AddAccountButton: View {
    @Binding var open: Bool
    var disabled: Bool

    var body: some View {
        Button { withAnimation(Theme.quick) { open.toggle() } } label: {
            ChipLabel(title: "Add account", icon: open ? "chevron.up" : "plus", tone: Theme.accentInk)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel("Add account")
    }
}

/// Add the account Claude Code is logged in to now, or a setup-token / API key.
struct AddAccountMenu: View {
    @Bindable var model: AppModel
    @Binding var open: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(icon: "person.crop.circle.badge.plus", title: "Add current Claude Code account",
                    detail: "The account Claude Code is logged in to now (cswap add)") {
                open = false
                Task {
                    if await model.perform(.addCurrent) { model.notice = "Added the current Claude Code account" }
                }
            }
            MenuRow(icon: "key.horizontal", title: "Add token…",
                    detail: "A setup-token or an API key (cswap add-token)") {
                open = false
                model.open(.addToken)
            }
        }
        .padding(4)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }
}

/// Import, export and the account tools that need a page of their own.
struct ListToolsMenu: View {
    @Bindable var model: AppModel

    var body: some View {
        Menu {
            Button("Export…") { export() }
            Button("Import…") { importAccounts() }
            Button("Import usage…") { importUsage() }
            Divider()
            Button("Priorities") { model.open(.priorities) }
            Button("Directory mappings") { model.open(.mappings) }
            Button("Unclaimed credentials") { model.open(.unclaimed) }
            Divider()
            Button("Remove all claude-swap data…", role: .destructive) { model.open(.purge) }
        } label: {
            Image(systemName: "ellipsis.circle").font(Theme.font(15)).foregroundStyle(Theme.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.listBusy)
        .help("Import, export and account tools")
        .accessibilityLabel("Account tools")
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "claude-swap-accounts.json"
        panel.allowedContentTypes = [.json]
        panel.message = "The file holds every account's login in plain text. Keep it private."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if await model.perform(.export(path: url.path)) { model.notice = "Exported to \(url.lastPathComponent)" }
        }
    }

    private func importAccounts() {
        guard let url = Panels.openJSON(message: "Choose a file made by Export (cswap export). Accounts already here are kept as they are.") else { return }
        Task {
            if await model.perform(.importAccounts(path: url.path, overwrite: false)) {
                model.notice = "Imported \(url.lastPathComponent)"
            }
        }
    }

    private func importUsage() {
        guard let url = Panels.openJSON(message: "Choose another machine's `cswap list --json` output to adopt its usage readings.") else { return }
        Task {
            if await model.perform(.importUsage(path: url.path)) { model.notice = "Imported usage from \(url.lastPathComponent)" }
        }
    }
}

enum Panels {
    static func openJSON(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = message
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func openFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = message
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// One entry of a hand-made menu: icon, title and a muted detail line.
struct MenuRow: View {
    var icon: String
    var title: String
    var detail: String
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Theme.gap) {
                Image(systemName: icon).font(Theme.font(13)).foregroundStyle(Theme.secondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.font(13, .medium))
                    Text(detail).font(Theme.font(11)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.gap)
            .background(hover ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// One account: tile, name with freshness, then per window the label, a pace
/// arrow tight against the percentage, and the reset countdown; the enabled
/// switch last. A click opens the details and actions below the row.
struct AccountRowView: View {
    @Bindable var model: AppModel
    let row: AccountRow
    @Binding var expanded: Bool
    var onDragStart: () -> Void = {}
    @State private var hover = false

    /// The name column; the rest of the row centres the usage block.
    static let nameWidth: CGFloat = 64

    var body: some View {
        let s = SlotSummary(row: row)
        let status = s.health.label { Format.clock($0) }
        VStack(alignment: .leading, spacing: Theme.gap) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    SlotTile(number: row.number, active: row.active, size: 20, surface: rowSurface)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(model.shortName(row)).font(Theme.font(13, .medium)).lineLimit(1).truncationMode(.tail)
                            if let glyph = s.glyph, !model.isProbing(row) {
                                Image(systemName: glyph)
                                    .font(Theme.font(11, .medium))
                                    .foregroundStyle(Theme.tone(s.health.tone))
                                    .help(status)
                            }
                        }
                        freshness(s)
                    }
                    .frame(width: Self.nameWidth, alignment: .leading)
                    // Equal spacers centre the usage block between the name and the switch.
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        WindowCellView(label: "5h", cell: s.fiveHourWindow, line: model.fiveHourLine(row), dimmed: row.isStale)
                        Text(" │ ").font(Theme.mono(WindowCellView.size)).foregroundStyle(Theme.muted.opacity(0.6)).fixedSize()
                        WindowCellView(label: "7d", cell: s.sevenDayWindow, line: model.sevenDayLine(row), dimmed: row.isStale)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 0)
                }
                .opacity(row.isEnabled ? 1 : 0.5)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() } }
                .onDrag {
                    onDragStart()
                    let provider = NSItemProvider()
                    provider.registerDataRepresentation(forTypeIdentifier: UTType.justSwapAccount.identifier,
                                                        visibility: .ownProcess) { done in
                        done(Data(), nil)
                        return nil
                    }
                    return provider
                } preview: {
                    Text(model.shortName(row)).font(Theme.font(13, .medium)).padding(6)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(s.accessibilityLabel(name: model.shortName(row), active: row.active,
                                                         enabled: row.isEnabled, status: status))
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(expanded ? "Hides the details" : "Shows the details and actions")
                .accessibilityAction { expanded.toggle() }

                Toggle("", isOn: Binding(
                    get: { row.isEnabled },
                    set: { v in Task { await model.setEnabled(row, v) } }
                ))
                .systemSwitch()
                .disabled(model.busyAccounts.contains(row.key) || model.listBusy)
                .help(row.isEnabled ? "In auto-rotation" : "Held out of auto-rotation")
                .accessibilityLabel("\(model.shortName(row)) in rotation")
            }
            .frame(minHeight: 32)

            if let err = model.rowErrors[row.key] { ErrorBanner(text: err) }
            if expanded { AccountDetails(model: model, row: row, summary: s) }
        }
        .padding(.horizontal, Theme.gap)
        .padding(.vertical, 2)
        .background(rowSurface)
        .onHover { hover = $0 }
        .animation(Theme.quick, value: hover)
    }

    private var rowSurface: Color { hover || expanded ? Theme.background : Theme.card }

    /// The age of the last check; the spinner while this slot is being checked.
    @ViewBuilder private func freshness(_ s: SlotSummary) -> some View {
        if model.isProbing(row) || row.usageFetchInFlight == true {
            ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 10, height: 11)
                .accessibilityLabel("Checking")
        } else if let f = SlotSummary.freshness(s.checkedAt) {
            Text(f)
                .font(Theme.mono(11))
                .foregroundStyle(row.isStale ? Theme.warn : Theme.muted)
                .help(row.isStale ? "Last good reading; the current one is unavailable"
                                  : s.checkedAt.map { "Checked \(Format.clock($0, seconds: true))" } ?? "")
        }
    }
}

/// `5h  42% 2h31m`: one monospaced Text of fixed character cells (see
/// `WindowCell.cells`), so labels, digits and countdowns line up across rows;
/// the percentage and the pace arrow are coloured runs inside it.
struct WindowCellView: View {
    var label: String
    var cell: SlotSummary.WindowCell
    var line: Double
    var dimmed = false

    /// The row's tightest text: two windows must fit beside the name and the switch.
    static let size: CGFloat = 10

    /// The cells' width from the mono face's advance, so trailing blanks count.
    static let width: CGFloat = {
        let advance = ("0" as NSString).size(withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: Theme.pointSize(size), weight: .regular)]).width
        return ceil(advance * CGFloat(SlotSummary.WindowCell.Cells.width))
    }()

    var body: some View {
        let c = cell.cells(label: label)
        var head = AttributedString(c.label + " " + c.pad)
        head.foregroundColor = Theme.muted
        var arrow = AttributedString(c.arrow)
        arrow.foregroundColor = Theme.warn
        var pct = AttributedString(c.percent)
        pct.foregroundColor = pctColor(cell.pct ?? 0).opacity(dimmed ? 0.6 : 1)
        pct.font = Theme.mono(Self.size, .medium)
        var tail = AttributedString(" " + c.countdown)
        tail.foregroundColor = Theme.muted
        return Text(head + arrow + pct + tail)
            .font(Theme.mono(Self.size))
            .lineLimit(1)
            .fixedSize()
            .frame(width: Self.width, alignment: .leading)
            .help(help)
    }

    /// No reading, the pace details when ahead, and the reset time.
    private var help: String {
        [cell.pct == nil ? "\(label): no reading" : nil,
         cell.aheadOfPace ? cell.paceHelp(window: label) { Format.clock($0) } : nil,
         cell.resetsAt.map { "Resets \(Format.clock($0))" }]
            .compactMap { $0 }.joined(separator: "\n")
    }

    /// Neutral, amber within 10 points of the switch line, red at the limit.
    private func pctColor(_ v: Double) -> Color {
        guard cell.pct != nil else { return Theme.muted }
        if v >= 100 { return Theme.bad }
        if v >= line - 10 { return Theme.warn }
        return Theme.primary
    }
}

/// An opened row: identity, full gauges with reset times, the sparkline for
/// the active slot, pace, token health, then the account's actions.
struct AccountDetails: View {
    @Bindable var model: AppModel
    let row: AccountRow
    let summary: SlotSummary

    var body: some View {
        let usage = row.displayUsage
        let health = summary.health
        VStack(alignment: .leading, spacing: Theme.gap) {
            Text(([model.email(row), model.organization(row), row.plan?.label] as [String?]).compactMap { $0 }
                .joined(separator: " · "))
                .font(Theme.font(11))
                .foregroundStyle(Theme.secondary)
                .lineLimit(2)
            if health != .healthy && !model.isProbing(row) {
                StatusTag(text: health.label { Format.clock($0) }, tone: health.tone)
                if let detail = health.detail {
                    Text(detail).font(Theme.font(11)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let usage {
                WindowRow(label: "5h", window: usage.fiveHour, line: model.fiveHourLine(row),
                          spent: summary.fiveHourSpent, dimmed: row.isStale)
                if row.active {
                    let spark = model.sparkline(for: row)
                    if spark.count > 1 {
                        Sparkline(values: spark)
                            .padding(.leading, Theme.windowLabel + Theme.gap)
                            .padding(.trailing, Theme.windowValue + Theme.gap)
                            .help("5h usage over the last 24 hours")
                    }
                }
                WindowRow(label: "7d", window: usage.sevenDay, line: model.sevenDayLine(row),
                          spent: summary.sevenDaySpent, dimmed: row.isStale, pace: usage.sevenDay?.expectedPct)
                if let pace = SlotSummary.paceLine(usage.sevenDay, clock: { Format.clock($0) }) {
                    Text(pace)
                        .font(Theme.font(10))
                        .foregroundStyle(summary.aheadOfPace ? Theme.warn : Theme.muted)
                        .padding(.leading, Theme.windowLabel + Theme.gap)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("No usage reading yet").font(Theme.font(11)).foregroundStyle(Theme.secondary)
            }
            HStack(alignment: .top, spacing: Theme.pad + 4) {
                Stat(title: "Last check", value: row.lastAttemptAt.map { Format.clock($0, seconds: true) } ?? "—",
                     sub: row.lastAttemptAt.map { Format.ago($0) })
                if row.isEnabled {
                    Stat(title: "Next", value: row.nextAttemptAt.map { Format.clock($0) } ?? "on poll",
                         sub: row.nextAttemptAt.map { $0 > Date() ? "in \(Format.countdown(to: $0))" : "due" })
                }
                if let exp = row.loginExpiresAt.flatMap(ISODate.parse) {
                    Stat(title: "Login expires", value: Format.clock(exp), sub: "in \(Format.countdown(to: exp))")
                }
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            AccountActions(model: model, row: row)
        }
        .padding(.leading, 26)
        .padding(.bottom, Theme.gap)
    }
}

/// Rename, switch line, priority tier, then Switch / Refresh / Swap / Replace
/// token / Remove. Replace token and Remove confirm inline.
struct AccountActions: View {
    @Bindable var model: AppModel
    let row: AccountRow
    @State private var alias = ""
    @State private var threshold = ""
    @State private var mode: Mode = .idle
    @State private var token = ""
    @FocusState private var focus: Field?

    enum Mode { case idle, replaceToken, confirmRemove }
    enum Field { case alias, threshold }

    var body: some View {
        let busy = model.busyAccounts.contains(row.key) || model.listBusy
        VStack(alignment: .leading, spacing: 6) {
            FieldLine(label: "Name") {
                TextField(model.options.redact ? "Alias" : row.email.split(separator: "@").first.map(String.init) ?? "Alias",
                          text: $alias)
                    .textFieldStyle(.roundedBorder).font(Theme.font(12)).frame(width: 120)
                    .focused($focus, equals: .alias)
                    .onSubmit(commitAlias)
                    .accessibilityLabel("Alias")
                Text("letters, digits, . - _").font(Theme.font(10)).foregroundStyle(Theme.muted)
            }
            FieldLine(label: "Switch at") {
                TextField(JSONScalar.number(model.number("autoswitch.threshold") ?? 90).description, text: $threshold)
                    .textFieldStyle(.roundedBorder).font(Theme.font(12).monospacedDigit()).frame(width: 52)
                    .multilineTextAlignment(.trailing)
                    .focused($focus, equals: .threshold)
                    .onSubmit(commitThreshold)
                    .accessibilityLabel("Switch-away threshold for this account")
                Text(row.threshold == nil ? "% · global default" : "% · own line, 50–99.9")
                    .font(Theme.font(10)).foregroundStyle(Theme.muted)
            }
            FieldLine(label: "Priority") {
                TierStepper(tier: row.priority ?? 0) { t in
                    Task { await model.perform(on: row) { .setPriority(slot: $0, tier: t) } }
                }
                Text("higher first · priority strategy only").font(Theme.font(10)).foregroundStyle(Theme.muted)
            }
            HStack(spacing: 6) {
                if !row.active {
                    ChipButton(title: "Switch to", icon: "arrow.left.arrow.right") {
                        Task { await model.switchTo(row) }
                    }
                }
                ChipButton(title: "Refresh", icon: "arrow.clockwise") { Task { await model.refresh(row) } }
                    .help("Check this account's usage now")
                    .disabled(model.isProbing(row))
                Menu {
                    ForEach(model.accounts.filter { $0.key != row.key }.sorted { $0.number < $1.number }) { other in
                        Button(model.label(forSlot: other.number)) {
                            Task { await model.swap(row, with: other) }
                        }
                    }
                } label: {
                    ChipLabel(title: "Swap with…", icon: "arrow.up.arrow.down")
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .disabled(model.accounts.count < 2)
                Spacer(minLength: 0)
                if busy { ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12) }
            }
            HStack(spacing: 6) {
                ChipButton(title: "Replace token", icon: "key.horizontal") { mode = mode == .replaceToken ? .idle : .replaceToken }
                ChipButton(title: "Remove", icon: "trash", tone: Theme.bad) { mode = mode == .confirmRemove ? .idle : .confirmRemove }
            }
            switch mode {
            case .replaceToken: replaceTokenForm
            case .confirmRemove: removeConfirm
            case .idle: EmptyView()
            }
        }
        .disabled(busy)
        .onAppear(perform: syncFields)
        .onChange(of: row) { _, _ in syncFields() }
        .onChange(of: focus) { old, _ in
            if old == .alias { commitAlias() }
            if old == .threshold { commitThreshold() }
        }
    }

    private var replaceTokenForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paste a setup-token (claude setup-token) or an API key for this account. Its name, switch line, priority, rotation state and identity stay; a token from another organization is refused.")
                .font(Theme.font(11)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Use a token of this same account: a token for a different email is a different account, so add that one with Add token instead.")
                .font(Theme.font(11)).foregroundStyle(Theme.warn)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                SecureField("sk-ant-…", text: $token)
                    .textFieldStyle(.roundedBorder).font(Theme.font(12))
                    .accessibilityLabel("New token")
                ChipButton(title: "Replace", icon: nil, tone: Theme.accentInk) {
                    let t = token
                    token = ""
                    mode = .idle
                    Task {
                        await model.perform(on: row) { .addToken(token: t, slot: $0, email: row.email) }
                    }
                }
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || AccountCommand.tokenProblem(token) != nil)
                ChipButton(title: "Cancel", icon: nil) { token = ""; mode = .idle }
            }
            if let problem = AccountCommand.tokenProblem(token) {
                Text(problem).font(Theme.font(10)).foregroundStyle(Theme.bad)
            }
        }
        .padding(Theme.gap)
        .background(Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
    }

    private var removeConfirm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Remove account \(row.number), \(model.name(row))? Its stored login is deleted from claude-swap\(row.active ? "; Claude Code stays logged in to it" : "").")
                .font(Theme.font(11)).foregroundStyle(Theme.primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ChipButton(title: "Remove \(model.shortName(row))", icon: "trash", tone: Theme.bad) {
                    mode = .idle
                    Task { await model.perform(on: row) { .remove(slot: $0) } }
                }
                ChipButton(title: "Cancel", icon: nil) { mode = .idle }
            }
        }
        .padding(Theme.gap)
        .background(Theme.bad.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
    }

    private func syncFields() {
        alias = model.options.redact ? "" : (row.alias ?? "")
        threshold = row.threshold.map { JSONScalar.number($0).description } ?? ""
    }

    private func commitAlias() {
        let v = alias.trimmingCharacters(in: .whitespaces)
        guard !model.options.redact, v != (row.alias ?? "") else { return }
        Task { await model.perform(on: row) { .setAlias(slot: $0, alias: v.isEmpty ? nil : v) } }
    }

    private func commitThreshold() {
        let v = threshold.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
        let current = row.threshold.map { JSONScalar.number($0).description } ?? ""
        guard v != current else { return }
        if v.isEmpty {
            Task { await model.perform(on: row) { .setThreshold(slot: $0, percent: nil) } }
        } else if let pct = Double(v) {
            Task { await model.perform(on: row) { .setThreshold(slot: $0, percent: pct) } }
        } else {
            model.rowErrors[row.key] = "Switch at takes a number from 50 to 99.9"
        }
    }
}

/// A label column and its controls, for the opened row's fields.
struct FieldLine<Content: View>: View {
    var label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(Theme.font(11)).foregroundStyle(Theme.secondary).frame(width: 52, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
    }
}

/// − tier + for `cswap priority`; each step writes at once.
struct TierStepper: View {
    var tier: Int
    var max = 1000
    var set: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            step("minus", tier - 1).disabled(tier <= 0)
            Text("\(tier)").font(Theme.mono(12, .medium)).frame(minWidth: 24)
            step("plus", tier + 1).disabled(tier >= max)
        }
        .frame(height: 20)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Priority tier \(tier)")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: if tier < max { set(tier + 1) }
            case .decrement: if tier > 0 { set(tier - 1) }
            @unknown default: break
            }
        }
    }

    private func step(_ icon: String, _ next: Int) -> some View {
        Button { set(next) } label: {
            Image(systemName: icon).font(Theme.font(10, .medium)).foregroundStyle(Theme.secondary)
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The slot number on a neutral tile; the active slot gets a coral dot.
struct SlotTile: View {
    var number: Int
    var active: Bool
    var size: CGFloat = 24
    var surface: Color = Theme.card

    var body: some View {
        Text("\(number)")
            .font(Theme.mono(size >= 24 ? 13 : 12, .medium))
            .foregroundStyle(Theme.primary)
            .frame(width: size, height: size)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
            .overlay(alignment: .bottomTrailing) {
                if active {
                    Circle().fill(Theme.accent)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(surface, lineWidth: 2))
                        .offset(x: 2, y: 2)
                        .help("Active")
                }
            }
    }
}

struct WindowRow: View {
    var label: String
    var window: UsageWindow?
    var line: Double
    var spent = false
    var dimmed = false
    var pace: Double?

    var body: some View {
        let pct = spent ? 100 : (window?.pct ?? 0)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.gap) {
                Text(label)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: Theme.windowLabel, alignment: .leading)
                UsageBar(pct: pct, color: Theme.bar(pct, line: line), line: line, pace: pace, dimmed: dimmed,
                         hasReading: spent || window?.pct != nil)
                Text(spent || window?.pct != nil ? Format.percent(pct) : "–")
                    .font(Theme.mono(12, .medium))
                    .foregroundStyle(pct >= 100 ? Theme.bad : Theme.primary)
                    .frame(width: Theme.windowValue, alignment: .trailing)
            }
            if let reset = window?.resetDate {
                Text(reset > Date() ? "Resets in \(Format.countdown(to: reset)) · \(Format.clock(reset))" : "Reset passed")
                    .font(Theme.font(10))
                    .foregroundStyle(Theme.muted)
                    .padding(.leading, Theme.windowLabel + Theme.gap)
            }
        }
    }
}

struct Stat: View {
    var title: String
    var value: String
    var sub: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(Theme.font(10)).foregroundStyle(Theme.muted)
            Text(value).font(Theme.figures(12, .medium)).foregroundStyle(Theme.primary)
            if let sub { Text(sub).font(Theme.font(10)).foregroundStyle(Theme.muted) }
        }
    }
}

import JustSwapCore
import Foundation
import Observation
import ServiceManagement

/// Launch arguments for development: `--preview-window` shows the popover in
/// a normal window, `--no-autoswitch` (or `JUST_SWAP_NO_AUTO=1`) keeps the
/// supervisor from ever starting, `--tab <name>` picks the first tab,
/// `--page <name>` opens an inner page (settings, unclaimed, mappings,
/// priorities, add-token, purge), `--expand <slot>` opens that slot's row,
/// `--add-menu` opens the Add account menu, `--redact` masks emails and
/// aliases for screenshots. `--preview-settings` is `--preview-window --page settings`.
struct LaunchOptions {
    var previewWindow = false
    var noAutoswitch = false
    var redact = false
    var tab: PopoverTab?
    var page: PopoverPage?
    var expandedSlot: Int?
    var addMenu = false

    static let current: LaunchOptions = {
        let args = ProcessInfo.processInfo.arguments
        var o = LaunchOptions()
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        o.previewWindow = args.contains("--preview-window") || args.contains("--preview-settings")
        o.noAutoswitch = args.contains("--no-autoswitch") || ProcessInfo.processInfo.environment["JUST_SWAP_NO_AUTO"] == "1"
        o.redact = args.contains("--redact")
        o.tab = value("--tab").flatMap(PopoverTab.init(argument:))
        o.page = value("--page").flatMap { PopoverPage(rawValue: $0.lowercased()) }
            ?? (args.contains("--preview-settings") ? .settings : nil)
        o.expandedSlot = value("--expand").flatMap(Int.init)
        o.addMenu = args.contains("--add-menu")
        return o
    }()
}

/// Pages that replace the tab content inside the popover, each with a back control.
enum PopoverPage: String {
    case settings, unclaimed, mappings, priorities
    case addToken = "add-token"
    case purge

    var title: String {
        switch self {
        case .settings: return "Settings"
        case .unclaimed: return "Unclaimed credentials"
        case .mappings: return "Directory mappings"
        case .priorities: return "Priorities"
        case .addToken: return "Add token"
        case .purge: return "Remove all claude-swap data"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    let options = LaunchOptions.current
    let client = CoreClient()
    @ObservationIgnored private var supervisor: AutoSupervisor?
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private let eventStore = SwitchEventStore()
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var watchedMtimes: [String: Date] = [:]
    @ObservationIgnored private var loadInFlight = false
    /// A reload asked for while another load ran: done once that one ends.
    @ObservationIgnored private var reloadQueued = false

    var tab: PopoverTab = .accounts
    var page: PopoverPage?

    // Accounts
    var list: ListPayload?
    var listError: String?
    var loadedAt: Date?
    var refreshing = false
    /// The running refresh skips disabled slots.
    var refreshIgnoresDisabled = false
    var refreshedAt: Date?
    var refreshError: String?
    /// Accounts with a change of their own running.
    var busyAccounts: Set<AccountKey> = []
    /// Accounts probed by their own Refresh.
    var probingAccounts: Set<AccountKey> = []
    var actionError: String?
    /// The last failed change per account, shown in its row.
    var rowErrors: [AccountKey: String] = [:]
    /// The last failed change on an inner page or the list menu.
    var pageError: String?
    /// A list-level change is running (add, import, swap, a reorder chain,
    /// purge …): slot numbers may change under it, so row actions wait.
    var listBusy = false
    /// What the last list-level change did ("Exported to …"), until the next change.
    var notice: String?

    // Account pages
    var mappings: [MappingsPayload.Mapping] = []
    var unclaimed: [UnclaimedPayload.Entry] = []

    // Config
    var settings: [ConfigSetting] = []
    var configError: String?

    // Autoswitch
    var autoState: AutoSupervisor.State = .stopped
    var lastPoll: AutoEvent.Poll?
    var lastSleep: AutoEvent.Sleep?
    var lastNoSwitch: AutoEvent.NoSwitch?
    var autoEvents: [AutoLogItem] = []

    // History and log
    var history: [SwitchRecord] = []
    var logLines: [SwapLog.Line] = []
    var samples: [String: [SwapLog.UsageSample]] = [:]

    // About
    var coreVersion: String?
    let coreCommit: String? = Bundle.main.url(forResource: "core-commit", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
        .trimmingCharacters(in: .whitespacesAndNewlines)

    var autoEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoEnabled, forKey: AppPrefs.autoSwitchEnabled)
            applyAutoEnabled()
        }
    }

    init() {
        LegacyMigration.run()
        AppPrefs.register()
        MenuBarPrefs.register()
        autoEnabled = UserDefaults.standard.bool(forKey: AppPrefs.autoSwitchEnabled)
        if let t = options.tab { tab = t }
        page = options.page
    }

    func start() {
        if !options.previewWindow { notifier.requestAuthorization() }
        if !options.noAutoswitch {
            let sup = AutoSupervisor(command: client.command)
            sup.onEvent = { [weak self] ev, line in self?.handle(ev, line: line) }
            sup.onState = { [weak self] s in self?.autoState = s }
            supervisor = sup
            applyAutoEnabled()
        }
        Task { await reloadAll() }
        // Display refresh from stored values only; never spends quota.
        schedule(every: 30, tolerance: 5) { await $0.reload() }
        // Cheap stat of the files a switch or a fetch rewrites.
        schedule(every: 1, tolerance: 0.5) { $0.checkWatchedFiles() }
        Task { coreVersion = try? await client.version() }
    }

    private func schedule(every interval: TimeInterval, tolerance: TimeInterval,
                          _ action: @escaping @MainActor (AppModel) async -> Void) {
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in if let self { await action(self) } }
        }
        t.tolerance = tolerance
        timers.append(t)
    }

    /// Quit: waits up to 5 s for the auto loop to exit (see `AutoSupervisor.shutdown`).
    func shutdown() {
        timers.forEach { $0.invalidate() }
        supervisor?.shutdown()
    }

    var autoswitchAvailable: Bool { supervisor != nil }

    private func applyAutoEnabled() {
        guard let supervisor else { return }
        if autoEnabled { supervisor.start() } else { supervisor.stop() }
    }

    // MARK: loading

    func reloadAll() async {
        await reload()
        await loadConfig()
        reloadLog()
    }

    func reload() async {
        guard !loadInFlight, !refreshing else {
            reloadQueued = true
            return
        }
        loadInFlight = true
        defer { loadInFlight = false }
        repeat {
            reloadQueued = false
            do {
                list = try await client.list(.noFetch)
                listError = nil
                loadedAt = Date()
            } catch {
                listError = error.localizedDescription
            }
        } while reloadQueued
    }

    /// Probes every slot now (`--refresh-all`), or with "Ignore disabled"
    /// the enabled ones and the active one (`--refresh`), and wakes the auto
    /// loop so it acts on the fresh values.
    func refresh() async {
        guard !refreshing else { return }
        let ignoreDisabled = UserDefaults.standard.bool(forKey: AppPrefs.ignoreDisabled)
        refreshing = true
        refreshIgnoresDisabled = ignoreDisabled
        refreshError = nil
        do {
            list = try await client.list(.refresh(ignoringDisabled: ignoreDisabled))
            listError = nil
            refreshedAt = Date()
            loadedAt = refreshedAt
            supervisor?.wake()
        } catch let e as CoreError where !ignoreDisabled && e.isUnsupportedFlag {
            refreshError = "This core has no --refresh-all yet: rebuild the app against a newer claude-swap, or turn on Ignore disabled in Settings."
        } catch {
            refreshError = error.localizedDescription
        }
        refreshing = false
        reloadLog()
        // A switch that landed during the probe asked for a reload.
        if reloadQueued { await reload() }
    }

    /// An account the running refresh, or its own Refresh, is probing.
    func isProbing(_ row: AccountRow) -> Bool {
        probingAccounts.contains(row.key) || refreshing && row.isProbed(ignoringDisabled: refreshIgnoresDisabled)
    }

    /// Probes one account now, disabled ones included (`list --refresh-slot`).
    func refresh(_ row: AccountRow) async {
        let key = row.key
        guard !listBusy, !probingAccounts.contains(key) else { return }
        probingAccounts.insert(key)
        defer { probingAccounts.remove(key) }
        guard let slot = await currentSlot(of: row) else { return }
        do {
            list = try await client.refreshSlot(slot)
            listError = nil
            loadedAt = Date()
            rowErrors[key] = nil
            supervisor?.wake()
        } catch let e as CoreError where e.isUnsupportedFlag {
            rowErrors[key] = "This core has no --refresh-slot yet: rebuild the app against a newer claude-swap"
        } catch {
            rowErrors[key] = error.localizedDescription
        }
    }

    func loadConfig() async {
        do {
            settings = try await client.config().settings
            configError = nil
        } catch {
            configError = error.localizedDescription
        }
    }

    func reloadLog() {
        let text = SwapLog.tail(SwapLog.logURL, maxBytes: 512 * 1024)
        let lines = SwapLog.lines(text)
        logLines = Array(lines.suffix(400))
        samples = SwapLog.usageSamples(text)
        let older = SwapLog.tail(SwapLog.rotatedURL, maxBytes: 512 * 1024)
        history = SwitchRecord.merge(log: SwapLog.switches(older) + SwapLog.switches(text), events: eventStore.load())
    }

    private func checkWatchedFiles() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            SwapLog.directory.appendingPathComponent("sequence.json").path,
            SwapLog.directory.appendingPathComponent("cache/usage.json").path,
            home.appendingPathComponent(".claude.json").path,
            SwapLog.logURL.path,
        ]
        var changed = false, logChanged = false
        for p in paths {
            let m = (try? FileManager.default.attributesOfItem(atPath: p)[.modificationDate]) as? Date
            if let m, watchedMtimes[p] != m {
                if watchedMtimes[p] != nil {
                    if p == SwapLog.logURL.path { logChanged = true } else { changed = true }
                }
                watchedMtimes[p] = m
            }
        }
        if logChanged { reloadLog() }
        if changed { Task { await reload() } }
    }

    // MARK: actions

    func switchTo(_ row: AccountRow) async {
        await perform(on: row) { .switchTo(slot: $0) }
    }

    func setEnabled(_ row: AccountRow, _ enabled: Bool) async {
        await perform(on: row) { .setEnabled(slot: $0, enabled: enabled) }
    }

    /// A list-level change through the core's write queue, then a reload;
    /// its error shows on the page or above the list.
    @discardableResult
    func perform(_ command: AccountCommand) async -> Bool {
        guard !listBusy else { return false }
        listBusy = true
        notice = nil
        defer { listBusy = false }
        let ok = await run(command) { self.pageError = $0 }
        await reloadAfterChange()
        return ok
    }

    /// A change to one account, on the slot the account holds now: the slot
    /// is read again first, and a moved or vanished account aborts with an
    /// error in its row. Rows wait while a list-level change runs.
    @discardableResult
    func perform(on row: AccountRow, _ command: (Int) -> AccountCommand) async -> Bool {
        let key = row.key
        guard !listBusy, !busyAccounts.contains(key) else { return false }
        busyAccounts.insert(key)
        notice = nil
        defer { busyAccounts.remove(key) }
        guard let slot = await currentSlot(of: row) else { return false }
        let ok = await run(command(slot)) { self.rowErrors[key] = $0 }
        await reloadAfterChange()
        return ok
    }

    /// Swaps two accounts' slots: a list-level change, its error in the row it started from.
    func swap(_ row: AccountRow, with other: AccountRow) async {
        guard !listBusy else { return }
        listBusy = true
        notice = nil
        defer { listBusy = false }
        guard let a = await currentSlot(of: row), let b = await currentSlot(of: other, errorKey: row.key) else { return }
        _ = await run(.swap(a, b)) { self.rowErrors[row.key] = $0 }
        await reloadAfterChange()
    }

    /// Drag and drop: the dragged account takes the drop row's place. The
    /// chain runs as one list-level change; a failed step undoes the steps
    /// already made, newest first, then reports.
    func reorder(moving source: AccountKey, onto target: AccountKey) async {
        guard !listBusy, source != target else { return }
        listBusy = true
        notice = nil
        defer { listBusy = false }
        do {
            let fresh = try await client.list(.noFetch).accounts
            guard let from = fresh.first(where: { $0.key == source })?.number,
                  let to = fresh.first(where: { $0.key == target })?.number else {
                pageError = "An account in that move is no longer in the list; nothing was moved"
                await reloadAfterChange()
                return
            }
            let moves = ReorderPlan.moves(slots: fresh.map(\.number).sorted(), from: from, to: to)
            var done: [AccountCommand] = []
            for move in moves {
                do {
                    try await client.perform(move)
                    done.append(move)
                } catch {
                    pageError = await rollBack(done, after: error)
                    await reloadAfterChange()
                    return
                }
            }
            pageError = nil
        } catch {
            pageError = error.localizedDescription
        }
        await reloadAfterChange()
    }

    /// Undoes applied reorder moves; the message for the failed move and the undo.
    private func rollBack(_ done: [AccountCommand], after error: Error) async -> String {
        let failure = "Moving the account failed: \(error.localizedDescription)"
        guard !done.isEmpty else { return failure }
        for undo in ReorderPlan.undo(done) {
            do {
                try await client.perform(undo)
            } catch {
                return "\(failure). Undoing the moves already made also failed (\(error.localizedDescription)): check the order"
            }
        }
        return "\(failure). The moves already made were undone"
    }

    /// The account's slot in a fresh read of the list, if it still holds the
    /// one the row showed; otherwise nil, with the reason in `errorKey`'s row
    /// (the page when that row is gone).
    private func currentSlot(of row: AccountRow, errorKey: AccountKey? = nil) async -> Int? {
        let key = errorKey ?? row.key
        let fail = { (text: String) in
            if self.accounts.contains(where: { $0.key == key }) { self.rowErrors[key] = text } else { self.pageError = text }
        }
        do {
            let fresh = try await client.list(.noFetch).accounts
            guard let now = fresh.first(where: { $0.key == row.key }) else {
                fail("\(name(row)) is no longer in the list; nothing was changed")
                await reload()
                return nil
            }
            guard now.number == row.number else {
                fail("\(name(row)) moved from slot \(row.number) to \(now.number); nothing was changed, try again")
                await reload()
                return nil
            }
            return now.number
        } catch {
            fail(error.localizedDescription)
            return nil
        }
    }

    /// Runs one command; on failure hands the message to `report`, on success clears it.
    private func run(_ command: AccountCommand, report: (String?) -> Void) async -> Bool {
        do {
            try await client.perform(command)
            report(nil)
            return true
        } catch {
            report(error.localizedDescription)
            return false
        }
    }

    private func reloadAfterChange() async {
        await reload()
        reloadLog()
    }

    func loadMappings() async {
        do {
            mappings = try await client.mappings().mappings
            pageError = nil
        } catch {
            pageError = error.localizedDescription
        }
    }

    func loadUnclaimed() async {
        do {
            unclaimed = try await client.unclaimed().entries
            pageError = nil
        } catch {
            pageError = error.localizedDescription
        }
    }

    func open(_ page: PopoverPage?) {
        pageError = nil
        self.page = page
    }

    func setConfig(_ key: String, _ value: String) async {
        await writeConfig(key) { try await self.client.configSet(key, value) }
    }

    func unsetConfig(_ key: String) async {
        await writeConfig(key) { try await self.client.configUnset(key) }
    }

    /// The engine reads only the `autoswitch` section, once at start; other
    /// sections are read per use (`usage.headerProbe` on every fetch).
    private func writeConfig(_ key: String, _ op: () async throws -> Void) async {
        do {
            try await op()
            configError = nil
            if key.hasPrefix("autoswitch.") { supervisor?.restart() }
        } catch {
            configError = error.localizedDescription
        }
        await loadConfig()
    }

    func setting(_ key: String) -> ConfigSetting? { settings.first { $0.key == key } }

    func number(_ key: String) -> Double? {
        setting(key).flatMap { $0.value.doubleValue ?? $0.default?.doubleValue }
    }

    /// The autoswitch line of the 5h window: a slot's own threshold, else `autoswitch.threshold`.
    func fiveHourLine(_ row: AccountRow? = nil) -> Double {
        row?.threshold ?? number("autoswitch.threshold") ?? 90
    }

    /// The autoswitch line of the 7d window: `autoswitch.weeklyThreshold`, else the 5h line.
    func sevenDayLine(_ row: AccountRow? = nil) -> Double {
        number("autoswitch.weeklyThreshold") ?? fiveHourLine(row)
    }

    // MARK: auto events

    private func handle(_ ev: AutoEvent, line: String) {
        switch ev {
        case .poll(let p): lastPoll = p
        case .sleep(let s): lastSleep = s
        case .noSwitch(let n): lastNoSwitch = n
        case .switched(let s) where s.dryRun != true:
            eventStore.append(rawLine: line)
            Task { await reload(); reloadLog() }
        default: break
        }
        if let item = AutoLogItem(ev) {
            autoEvents.insert(item, at: 0)
            if autoEvents.count > 50 { autoEvents.removeLast() }
        }
        if let n = ev.notification { notifier.post(title: n.title, body: n.body) }
    }

    // MARK: display helpers

    var accounts: [AccountRow] { list?.accounts ?? [] }
    var activeAccount: AccountRow? { accounts.first { $0.active } }

    func name(_ row: AccountRow) -> String {
        options.redact ? "Slot \(row.number)" : row.displayName
    }

    /// Alias or email local part, for the status item.
    func shortName(_ row: AccountRow) -> String {
        options.redact ? "Slot \(row.number)" : row.shortName
    }

    func organization(_ row: AccountRow) -> String? {
        guard let org = row.organizationName, !org.isEmpty else { return nil }
        return options.redact ? "Org \(row.number)" : org
    }

    func email(_ row: AccountRow) -> String {
        options.redact ? "account\(row.number)@example.com" : row.email
    }

    func label(forSlot n: Int?) -> String {
        guard let n else { return "—" }
        if options.redact { return "Slot \(n)" }
        if let row = accounts.first(where: { $0.number == n }) { return "#\(n) \(name(row))" }
        return "#\(n)"
    }

    /// Masks known emails in free text (log lines) in redact mode.
    func redacted(_ text: String) -> String {
        guard options.redact else { return text }
        var out = text
        for row in accounts {
            out = out.replacingOccurrences(of: row.email, with: email(row))
            if let alias = row.alias, !alias.isEmpty { out = out.replacingOccurrences(of: alias, with: name(row)) }
        }
        return out
    }

    func sparkline(for row: AccountRow) -> [Double] {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        return (samples[row.email] ?? []).filter { $0.date >= cutoff }.compactMap(\.fiveHour)
    }

    // MARK: launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                actionError = nil
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

struct AutoLogItem: Identifiable {
    let id = UUID()
    let date: Date
    let icon: String
    let text: String
    let tone: SlotHealth.Tone

    init?(_ ev: AutoEvent) {
        date = ev.timestamp ?? Date()
        switch ev {
        case .switched(let e):
            icon = "arrow.left.arrow.right"
            text = "\(e.dryRun == true ? "Would switch" : "Switched") #\(e.from?.number.map(String.init) ?? "–") → #\(e.to?.number.map(String.init) ?? "?") · \(e.trigger ?? "")"
            tone = .good
        case .noSwitch(let e):
            icon = "pause.circle"
            text = "No switch: \(e.reason ?? "")\(e.detail.map { $0.isEmpty ? "" : " (\($0))" } ?? "")"
            tone = .neutral
        case .quarantined(let e):
            icon = "exclamationmark.octagon"
            text = "Account-\(e.number ?? "?") quarantined: \(e.reason ?? "")"
            tone = .bad
        case .unquarantined(let e):
            icon = "checkmark.circle"
            text = "Account-\(e.number ?? "?") back in rotation"
            tone = .good
        case .allExhausted:
            icon = "battery.0percent"
            text = "All accounts exhausted"
            tone = .bad
        case .error(let e):
            icon = "exclamationmark.triangle"
            text = e.message ?? "error"
            tone = .warn
        case .configWarning(let e):
            icon = "exclamationmark.bubble"
            text = e.message ?? "config warning"
            tone = .warn
        case .poll, .sleep, .unknown:
            return nil
        }
    }
}

import Foundation
import Testing
@testable import JustSwapCore

@Suite("Account commands: exact argv and stdin")
struct AccountCommandArgvTests {
    @Test(arguments: [
        (AccountCommand.switchTo(slot: 3), ["switch", "3"], nil as String?),
        (.setEnabled(slot: 2, enabled: false), ["disable", "2"], nil),
        (.setEnabled(slot: 2, enabled: true), ["enable", "2"], nil),
        (.setAlias(slot: 1, alias: "work"), ["alias", "1", "work"], nil),
        (.setAlias(slot: 1, alias: "  work "), ["alias", "1", "work"], nil),
        (.setAlias(slot: 1, alias: nil), ["alias", "1", "--unset"], nil),
        (.setAlias(slot: 1, alias: "  "), ["alias", "1", "--unset"], nil),
        (.setThreshold(slot: 4, percent: 85), ["threshold", "4", "85"], nil),
        (.setThreshold(slot: 4, percent: 99.9), ["threshold", "4", "99.9"], nil),
        (.setThreshold(slot: 4, percent: nil), ["threshold", "4", "--unset"], nil),
        (.setPriority(slot: 2, tier: 3), ["priority", "2", "3"], nil),
        (.setPriority(slot: 2, tier: 0), ["priority", "2", "--unset"], nil),
        (.addCurrent, ["add"], nil),
        (.addToken(token: " sk-ant-oat01-x\n", slot: nil, email: nil), ["add-token", "-"], "sk-ant-oat01-x\n"),
        (.addToken(token: "sk-ant-oat01-x", slot: nil, email: "me@example.com"),
         ["add-token", "-", "--email", "me@example.com"], "sk-ant-oat01-x\n"),
        (.addToken(token: "sk-ant-api03-k", slot: 5, email: "me@example.com"),
         ["add-token", "-", "--slot", "5", "--email", "me@example.com"], "sk-ant-api03-k\ny\n"),
        (.remove(slot: 2), ["remove", "2"], "y\n"),
        (.move(slot: 1, to: 3), ["move", "1", "3"], nil),
        (.swap(1, 2), ["swap", "1", "2"], nil),
        (.export(path: "/tmp/a b.json"), ["export", "/tmp/a b.json"], nil),
        (.importAccounts(path: "/tmp/a.json", overwrite: false), ["import", "/tmp/a.json"], nil),
        (.importAccounts(path: "/tmp/a.json", overwrite: true), ["import", "/tmp/a.json", "--force"], nil),
        (.importUsage(path: "/tmp/u.json"), ["import-usage", "/tmp/u.json"], nil),
        (.purgeUnclaimed(id: "abc123"), ["unclaimed", "--purge", "abc123"], nil),
        (.map(slot: 2, path: "/Users/x/work"), ["map", "2", "/Users/x/work"], nil),
        (.unmap(path: "/Users/x/work"), ["unmap", "/Users/x/work"], nil),
        (.purgeAll, ["purge"], "y\n"),
    ])
    func invocation(_ command: AccountCommand, _ args: [String], _ stdin: String?) {
        #expect(command.invocation.args == args)
        #expect(command.invocation.stdin == stdin)
    }

    @Test func tokensWithInnerWhitespaceAreRejected() {
        #expect(AccountCommand.tokenProblem(" sk-ant-oat01-x\n") == nil)
        #expect(AccountCommand.tokenProblem("") == nil)
        #expect(AccountCommand.tokenProblem("sk-ant-oat01-x y") != nil)
        #expect(AccountCommand.tokenProblem("sk-ant-oat01-x\nsk-ant-oat01-y") != nil)
        #expect(AccountCommand.tokenProblem("sk-ant-oat01-x\ty") != nil)
    }

    @Test func listingsAndSlotRefresh() {
        #expect(AccountListing.mappings.args == ["map", "--json"])
        #expect(AccountListing.unclaimed.args == ["unclaimed", "--json"])
        #expect(AccountListing.refreshSlot(4).args == ["list", "--json", "--refresh-slot", "4"])
    }

    @Test func clientSendsArgvAndStdinToTheCore() async throws {
        let core = try FakeCore(script: """
        d="$(dirname "$0")"
        echo "$*" >> "$d/calls"
        cat >> "$d/stdin"
        """)
        defer { core.cleanup() }
        let client = CoreClient(command: core.command, environment: CoreEnvironment.make())
        try await client.perform(.addToken(token: "sk-ant-oat01-secret", slot: 2, email: nil))
        try await client.perform(.remove(slot: 3))
        try await client.perform(.move(slot: 1, to: 2))
        let calls = try String(contentsOf: core.dir.appendingPathComponent("calls"), encoding: .utf8)
        #expect(calls == "add-token - --slot 2\nremove 3\nmove 1 2\n")
        let stdin = try String(contentsOf: core.dir.appendingPathComponent("stdin"), encoding: .utf8)
        #expect(stdin == "sk-ant-oat01-secret\ny\ny\n")
    }

    /// More stdin than a pipe buffers, to a core that exits unread: the write
    /// hits a closed pipe, which must not raise SIGPIPE in the app.
    @Test func aCoreThatExitsWithoutReadingStdinIsNoCrash() async throws {
        let core = try FakeCore(script: "exit 0")
        defer { core.cleanup() }
        let client = CoreClient(command: core.command, environment: CoreEnvironment.make())
        let r = try await client.run(["x"], timeout: 10, stdin: String(repeating: "a", count: 512 * 1024))
        #expect(r.status == 0)
    }
}

@Suite("Core error parsing")
struct CoreErrorParsingTests {
    private func result(_ status: Int32, out: String = "", err: String = "") -> ProcessResult {
        ProcessResult(status: status, stdout: Data(out.utf8), stderr: Data(err.utf8))
    }

    @Test func stripsTheCoresErrorPrefix() {
        let e = CoreError.from(result(1, err: "Warning: something\nError: No account found with identifier: 9\n"))
        #expect(e == .failed(status: 1, message: "No account found with identifier: 9", type: nil))
    }

    @Test func stripsArgparsesPrefix() {
        let e = CoreError.from(result(2, err: "usage: cswap alias ...\ncswap alias: error: --unset does not take a NAME argument\n"))
        #expect(e.errorDescription == "--unset does not take a NAME argument")
    }

    @Test func capitalizesAValueErrorLine() {
        let e = CoreError.from(result(1, err: "Error: priority must be an integer between 0 and 1000"))
        #expect(e.errorDescription == "Priority must be an integer between 0 and 1000")
    }

    @Test func keepsTheJSONEnvelopeFirst() {
        let e = CoreError.from(result(1, out: #"{"schemaVersion":1,"error":{"type":"AccountNotFoundError","message":"Account-9 does not exist"}}"#,
                                      err: "Error: other"))
        #expect(e == .failed(status: 1, message: "Account-9 does not exist", type: "AccountNotFoundError"))
    }

    @Test func emptyStderrNamesTheStatus() {
        #expect(CoreError.from(result(3)).errorDescription == "exit status 3")
    }

    @Test func cancelledOnExitZeroIsAFailure() {
        #expect(throws: CoreError.self) { try CoreError.checkWrite(result(0, out: "Slot 2 already occupied\nCancelled\n")) }
        #expect(throws: Never.self) { try CoreError.checkWrite(result(0, out: "Set alias 'dev' for Account 2\n")) }
    }

    @Test func clientReportsTheStderrLine() async throws {
        let core = try FakeCore(script: "echo 'Error: Alias must not be purely numeric' >&2; exit 1\n")
        defer { core.cleanup() }
        let client = CoreClient(command: core.command, environment: CoreEnvironment.make())
        await #expect(throws: CoreError.failed(status: 1, message: "Alias must not be purely numeric", type: nil)) {
            try await client.perform(.setAlias(slot: 1, alias: "123"))
        }
    }
}

@Suite("Drag-and-drop reorder")
struct ReorderPlanTests {
    @Test func dragDownIsAChainOfNeighbourSwaps() {
        let moves = ReorderPlan.moves(slots: [1, 2, 3, 4], from: 1, to: 3)
        #expect(moves == [.move(slot: 1, to: 2), .move(slot: 2, to: 3)])
        let after = ReorderPlan.apply(moves, to: [1: "a", 2: "b", 3: "c", 4: "d"])
        #expect(after == [1: "b", 2: "c", 3: "a", 4: "d"])
    }

    @Test func dragUpShiftsTheRowsBetweenDown() {
        let moves = ReorderPlan.moves(slots: [1, 2, 5, 7], from: 7, to: 2)
        #expect(moves == [.move(slot: 7, to: 5), .move(slot: 5, to: 2)])
        let after = ReorderPlan.apply(moves, to: [1: "a", 2: "b", 5: "c", 7: "d"])
        #expect(after == [1: "a", 2: "d", 5: "b", 7: "c"])
    }

    @Test func undoPutsTheOrderBack() {
        let order = [1: "a", 2: "b", 5: "c", 7: "d"]
        let moves = ReorderPlan.moves(slots: [1, 2, 5, 7], from: 1, to: 7)
        for applied in 1...moves.count {
            let done = Array(moves.prefix(applied))
            #expect(ReorderPlan.apply(ReorderPlan.undo(done), to: ReorderPlan.apply(done, to: order)) == order)
        }
        #expect(ReorderPlan.undo([.move(slot: 7, to: 5), .move(slot: 5, to: 2)])
                == [.move(slot: 2, to: 5), .move(slot: 5, to: 7)])
    }

    @Test func neighboursAreOneSwap() {
        #expect(ReorderPlan.moves(slots: [1, 2], from: 2, to: 1) == [.move(slot: 2, to: 1)])
    }

    @Test func noMoveForTheSameRowOrAnUnknownSlot() {
        #expect(ReorderPlan.moves(slots: [1, 2, 3], from: 2, to: 2).isEmpty)
        #expect(ReorderPlan.moves(slots: [1, 2, 3], from: 9, to: 2).isEmpty)
    }
}

@Suite("Strategy descriptions")
struct StrategyInfoTests {
    @Test func everySchemaChoiceIsDescribed() throws {
        let payload = try JSONDecoder().decode(ConfigPayload.self, from: fixture("config-schema.json"))
        let choices = try #require(payload.settings.first { $0.key == "autoswitch.strategy" }?.choices)
        #expect(choices == ["best", "weekly-first", "consume-first", "priority-consume-first"])
        #expect(StrategyInfo.undescribed(choices).isEmpty)
        for c in choices {
            let text = try #require(StrategyInfo.summary(c))
            #expect(text.count > 60)
        }
    }

    @Test func theVendoredCoreOffersNoUndescribedStrategy() throws {
        let settings = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vendor/claude-swap/src/claude_swap/settings.py")
        let source = try String(contentsOf: settings, encoding: .utf8)
        let block = try #require(source.range(of: "AUTOSWITCH_STRATEGIES = (").map { source[$0.upperBound...] })
        let tuple = block.prefix { $0 != ")" }
        let names = tuple.split(separator: "\"").enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
        #expect(!names.isEmpty)
        #expect(StrategyInfo.undescribed(names).isEmpty)
    }

    @Test func unknownChoiceIsReported() {
        #expect(StrategyInfo.undescribed(["best", "round-robin"]) == ["round-robin"])
        #expect(StrategyInfo.summary("round-robin") == nil)
    }

    @Test func interplayNamesTiersAndPerAccountLines() {
        #expect(StrategyInfo.interplay.contains("Priority tiers"))
        #expect(StrategyInfo.interplay.contains("per-account threshold"))
        #expect(StrategyInfo.interplay.contains("autoswitch.weeklyThreshold"))
        #expect(StrategyInfo.interplay.contains("includeApiKeyAccounts"))
    }

    /// The engine code each key claim of the descriptions rests on; a core
    /// sync that changes one fails here, and the text needs a fresh look.
    @Test func theClaimsMatchTheVendoredEngine() throws {
        let core = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vendor/claude-swap/src/claude_swap")
        let engine = try String(contentsOf: core.appendingPathComponent("autoswitch.py"), encoding: .utf8)
        let lines = try String(contentsOf: core.appendingPathComponent("lines.py"), encoding: .utf8)
        // Only a move at or before the line has the landing gate; the at-limit and failover escapes skip it.
        #expect(engine.contains("if trigger in (\"proactive\", \"consume-first\"):\n                # Landing must be healthy"))
        // Priority tiers: no escape over the line, and nothing qualifying blocks.
        #expect(engine.contains("even at-limit/failover never selects an account\n        at its switch line"))
        #expect(engine.contains("no candidate is below every switch line with readable usage; waiting for recovery"))
        // API-key accounts: last resort, never for a before-the-line move.
        #expect(engine.contains("and trigger not in (\"consume-first\", \"priority\")"))
        // A weekly line keeps the 7-day windows whatever the account's own threshold.
        #expect(lines.contains("if weekly_threshold is None or label == FIVE_HOUR_LABEL:\n        return threshold"))
        #expect(StrategyInfo.entry("priority-consume-first")?.picks.contains("waits") == true)
        #expect(StrategyInfo.entry("best")?.picks.contains("even one over its own line") == true)
    }
}

@Suite("Settings page and tabs")
struct SettingsLayoutTests {
    @Test func autoswitchKeysGoToTheirTabAndTheRestToTheSettingsPage() throws {
        let settings = try JSONDecoder().decode(ConfigPayload.self, from: fixture("config-schema.json")).settings
        let auto = SettingsLayout.autoswitch(settings)
        let general = SettingsLayout.generalSections(settings)
        #expect(!auto.isEmpty && auto.allSatisfy { $0.key.hasPrefix("autoswitch.") })
        #expect(general.map(\.section) == ["ui", "run", "updates", "usage"])
        let all = auto.map(\.key) + general.flatMap { $0.settings.map(\.key) }
        #expect(Set(all) == Set(settings.map(\.key)))
        #expect(all.count == settings.count)
        let probe = try #require(general.first { $0.section == "usage" }?.settings.first { $0.key == "usage.headerProbe" })
        #expect(probe.isLocked)
    }

    /// Checked on the dictionaries: `register` writes the process-wide
    /// registration domain and would leak into other suites.
    @Test func prefsRegisterTheirDefaults() throws {
        #expect(AppPrefs.defaults == [AppPrefs.autoSwitchEnabled: true, AppPrefs.ignoreDisabled: false,
                                      AppPrefs.showLogTab: false])
        let menu = MenuBarPrefs.defaults
        #expect(menu[MenuBarPrefs.logo] as? Bool == true)
        #expect(menu[MenuBarPrefs.account] as? Bool == false)
        #expect(menu[MenuBarPrefs.hidden] as? Bool == false)
        #expect(menu[MenuBarPrefs.separator] as? String == TitleSeparator.standard)
        // The keys the settings page binds; renaming one would drop the user's choice.
        #expect([AppPrefs.ignoreDisabled, AppPrefs.showLogTab, MenuBarPrefs.logo, MenuBarPrefs.account,
                 MenuBarPrefs.organization, MenuBarPrefs.fiveHour, MenuBarPrefs.sevenDay, MenuBarPrefs.hidden,
                 MenuBarPrefs.separator, MenuBarPrefs.customSeparator]
                == ["refreshIgnoresDisabled", "showLogTab", "menuBarShowLogo", "menuBarShowAccount",
                    "menuBarShowOrganization", "menuBarShowFiveHour", "menuBarShowSevenDay", "menuBarIconHidden",
                    "menuBarSeparator", "menuBarSeparatorCustom"])
    }

    @Test func logTabOnlyWhenShown() {
        #expect(PopoverTab.visible(showLog: false) == [.accounts, .autoswitch, .history])
        #expect(PopoverTab.visible(showLog: true) == [.accounts, .autoswitch, .history, .log])
    }

    @Test func oldTabNamesOpenAccounts() {
        #expect(PopoverTab(argument: "slots") == .accounts)
        #expect(PopoverTab(argument: "Tokens") == .accounts)
        #expect(PopoverTab(argument: "history") == .history)
        #expect(PopoverTab(argument: "nope") == nil)
    }
}

@Suite("Collapsed row cells")
struct WindowCellTests {
    @Test func compactCountdown() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Format.compactCountdown(to: now.addingTimeInterval(34 * 60 + 5), from: now) == "34m")
        #expect(Format.compactCountdown(to: now.addingTimeInterval(2 * 3600 + 21 * 60), from: now) == "2h21m")
        #expect(Format.compactCountdown(to: now.addingTimeInterval(5 * 86400 + 17 * 3600 + 59), from: now) == "5d17h")
        #expect(Format.compactCountdown(to: now.addingTimeInterval(20), from: now) == "<1m")
        #expect(Format.compactCountdown(to: now.addingTimeInterval(-5), from: now) == nil)
    }

    private func cell(_ pct: Double?, ahead: Bool = false, resetIn seconds: TimeInterval? = nil,
                      now: Date) -> SlotSummary.WindowCell {
        var c = SlotSummary.WindowCell(nil, pct: pct)
        c.aheadOfPace = ahead
        c.resetsAt = seconds.map { now.addingTimeInterval($0) }
        return c
    }

    @Test func cellsHaveFixedWidths() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let texts = [
            cell(5, now: now), cell(42, resetIn: 34 * 60 + 5, now: now), cell(100, resetIn: 2 * 3600 + 31 * 60, now: now),
            cell(nil, now: now), cell(55, ahead: true, resetIn: 4 * 86400 + 18 * 3600 + 30, now: now),
            cell(100, ahead: true, resetIn: 20, now: now), cell(0, ahead: true, now: now),
        ].map { $0.cells(label: "7d", now: now) }
        for c in texts {
            #expect(c.text.count == SlotSummary.WindowCell.Cells.width)
            #expect(c.label.count == 2 && c.countdown.count == 5)
            #expect((c.pad + c.arrow + c.percent).count == 5)
        }
        #expect(texts.map(\.text) == [
            "7d    5%      ",
            "7d   42% 34m  ",
            "7d  100% 2h31m",
            "7d     –      ",
            "7d  ↗55% 4d18h",
            "7d ↗100% <1m  ",
            "7d   ↗0%      ",
        ])
    }

    @Test func cellsKeepTheRunsApart() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let ahead = cell(55, ahead: true, resetIn: 5 * 86400 + 18 * 3600 + 59, now: now).cells(label: "5h", now: now)
        #expect(ahead == .init(label: "5h", pad: " ", arrow: "↗", percent: "55%", countdown: "5d18h"))
        let none = cell(nil, ahead: false, resetIn: -5, now: now).cells(label: "5h", now: now)
        #expect(none == .init(label: "5h", pad: "    ", arrow: "", percent: "–", countdown: "     "))
        let rounded = cell(4.6, now: now).cells(label: "5h", now: now)
        #expect(rounded.percent == "5%" && rounded.pad == "   " && rounded.arrow.isEmpty)
    }

    @Test func eachWindowCarriesItsOwnPace() throws {
        let p = try JSONDecoder().decode(ListPayload.self, from: fixture("list-rich.json"))
        let s = SlotSummary(row: p.accounts[1])
        #expect(s.sevenDayWindow.aheadOfPace)
        #expect(!s.fiveHourWindow.aheadOfPace)
        #expect(s.sevenDayWindow.paceHelp(window: "7d") { _ in "Nov 8 08:44" }.hasPrefix("7d ahead of pace"))
    }

    @Test func decodesPriority() throws {
        let row = try JSONDecoder().decode(AccountRow.self, from: Data(#"{"number":2,"email":"b@example.com","active":false,"usageStatus":"ok","priority":3}"#.utf8))
        #expect(row.priority == 3)
    }

    @Test func decodesTheListings() throws {
        let m = try JSONDecoder().decode(MappingsPayload.self, from: Data(#"{"schemaVersion":1,"mappings":[{"path":"/Users/x/w","email":"b@example.com","organizationUuid":"","slot":null}]}"#.utf8))
        #expect(m.mappings.first?.slot == nil)
        let u = try JSONDecoder().decode(UnclaimedPayload.self, from: Data(#"{"schemaVersion":1,"entries":[{"id":"e1","slot":"2","reason":null}]}"#.utf8))
        #expect(u.entries.first?.slot == "2")
    }
}

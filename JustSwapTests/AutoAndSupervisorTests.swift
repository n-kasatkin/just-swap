import Darwin
import Foundation
import Testing
@testable import JustSwapCore

@Suite("auto --json events")
struct AutoEventTests {
    let events: [AutoEvent]

    init() throws {
        let text = String(decoding: try fixture("auto-events.jsonl"), as: UTF8.self)
        events = text.split(separator: "\n").compactMap { AutoEvent.parse($0) }
    }

    @Test func parsesEveryKindAndSkipsGarbage() {
        #expect(events.count == 11)  // 10 known + 1 future kind; "not json" dropped
        guard case .poll(let p) = events[0] else { Issue.record("poll"); return }
        #expect(p.active?.number == 1)
        #expect(p.headroomPct?["2"] == .some(nil))
        #expect(p.windowsPct?["1"]?["5h"] == 42)
        #expect(p.weeklyThreshold == 97)
        #expect(p.fetchErrors?["2"] == "http-429")
        guard case .switched(let s) = events[1] else { Issue.record("switch"); return }
        #expect(s.trigger == "proactive" && s.to?.number == 3 && s.dryRun == false)
        guard case .sleep(let sl) = events[7] else { Issue.record("sleep"); return }
        #expect(sl.seconds == 60)
        #expect(events[10] == .unknown(kind: "future-kind"))
        #expect(events.allSatisfy { $0.timestamp != nil || $0 == .unknown(kind: "future-kind") })
    }

    @Test func notificationsMirrorTheOldMenuBar() {
        let titles = events.compactMap { $0.notification?.title }
        #expect(titles == ["Auto-switched account", "Account quarantined", "All accounts exhausted", "Configuration warning"])
        // A dry-run switch never notifies.
        guard case .switched(let dry) = events[2] else { Issue.record("dry run"); return }
        #expect(dry.dryRun == true)
        #expect(AutoEvent.switched(dry).notification == nil)
    }

    @Test func pollLinesMatchTheEngine() {
        // A slot's own 5h line (85) with no weekly line anywhere: 7d switches at 85, not the global 90.
        let slotLine = AutoEvent.Poll(threshold: 85)
        #expect(slotLine.line(for: "5h", configuredWeekly: nil, fallback: 90) == 85)
        #expect(slotLine.line(for: "7d", configuredWeekly: nil, fallback: 90) == 85)
        #expect(slotLine.line(for: "7d", configuredWeekly: 95, fallback: 90) == 95)
        // The poll's weekly line wins over the configured one.
        let weekly = AutoEvent.Poll(threshold: 85, weeklyThreshold: 97)
        #expect(weekly.line(for: "7d", configuredWeekly: 95, fallback: 90) == 97)
        #expect(weekly.line(for: "5h", configuredWeekly: 95, fallback: 90) == 85)
        #expect(AutoEvent.Poll().line(for: "7d", configuredWeekly: nil, fallback: 90) == 90)
    }

    @Test func lineBufferKeepsPartialLines() {
        var b = LineBuffer()
        #expect(b.append(Data("{\"a\":1}\n{\"b\"".utf8)) == ["{\"a\":1}"])
        #expect(b.append(Data(":2}\n\n".utf8)) == ["{\"b\":2}", ""])
    }

    @Test func backoffGrowsCapsAndResets() {
        var b = RestartBackoff()
        let delays = (0..<7).map { _ in b.nextDelay(ranFor: 1) }
        #expect(delays == [2, 4, 8, 16, 32, 60, 60])
        #expect(b.nextDelay(ranFor: 120) == 2)
    }
}

@Suite("Switch history")
struct HistoryTests {
    @Test func logLinesAndEventsMerge() throws {
        let log = """
        2026-11-04 22:10:01,100 - INFO - Switched from account 2 to 1
        2026-11-05 10:59:26,862 - INFO - usage a1@example.com: 5h 38% (resets 14:10) · 7d 32% (resets Nov 11 06:00)
        2026-11-05 11:00:00,000 - INFO - Switched from account 1 to 3
        garbage line
        """
        let fromLog = SwapLog.switches(log)
        #expect(fromLog.count == 2)
        #expect(fromLog[1].from == 1 && fromLog[1].to == 3 && fromLog[1].trigger == nil)
        let matching = SwitchRecord(date: fromLog[1].date.addingTimeInterval(2), from: 1, to: 3, trigger: "proactive")
        let separate = SwitchRecord(date: fromLog[1].date.addingTimeInterval(600), from: 3, to: 2, trigger: "at-limit")
        let merged = SwitchRecord.merge(log: fromLog, events: [matching, separate])
        #expect(merged.count == 3)
        #expect(merged.map(\.to) == [2, 3, 1])
        #expect(merged[1].trigger == "proactive")
    }

    @Test func usageSamplesFromLog() {
        let log = """
        2026-11-05 10:59:26,862 - INFO - usage a1@example.com: 5h 38% (resets 14:10) · 7d 32% (resets Nov 11 06:00)
        2026-11-05 11:03:26,887 - INFO - usage a1@example.com: 5h 39.5% (resets 14:10) · 7d 33% (resets Nov 11 06:00)
        2026-11-05 11:04:00,000 - INFO - usage a2@example.com: 7d 90% (resets Nov 8 05:00)
        2026-11-05 11:05:00,000 - INFO - usage a3@example.com: token expired
        """
        let s = SwapLog.usageSamples(log)
        #expect(s["a1@example.com"]?.compactMap(\.fiveHour) == [38, 39.5])
        #expect(s["a1@example.com"]?.compactMap(\.sevenDay) == [32, 33])
        #expect(s["a2@example.com"]?.first?.fiveHour == nil)
        #expect(s["a2@example.com"]?.first?.sevenDay == 90)
        #expect(s["a3@example.com"] == nil)
    }

    @Test func storedEventsRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SwitchEventStore(url: dir.appendingPathComponent("switches.jsonl"))
        let lines = String(decoding: try fixture("auto-events.jsonl"), as: UTF8.self).split(separator: "\n")
        lines.forEach { store.append(rawLine: String($0)) }
        let loaded = store.load()
        #expect(loaded.count == 1)  // only the live switch; the dry run is skipped
        #expect(loaded.first?.trigger == "proactive")
    }
}

@Suite("Supervisor singleton")
struct SingletonTests {
    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("csb-\(UUID().uuidString)")
    }

    @Test func secondHolderIsRefusedUntilRelease() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = SupervisorLock(directory: dir), b = SupervisorLock(directory: dir)
        #expect(a.acquire())
        #expect(!b.acquire())
        a.release()
        #expect(b.acquire())
        b.release()
    }

    @Test func pidFileRoundTrip() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let l = SupervisorLock(directory: dir)
        #expect(l.acquire())
        #expect(l.readPID() == nil)
        l.writePID(4242)
        #expect(l.readPID() == 4242)
        l.clearPID()
        #expect(l.readPID() == nil)
    }

    @Test func recognisesOnlyAutoLoops() {
        #expect(StaleChildReaper.isAutoLoop("/App/Contents/Resources/python/bin/python3 -I -B -m claude_swap auto --json"))
        #expect(StaleChildReaper.isAutoLoop("/Users/x/.local/bin/cswap auto --json"))
        #expect(!StaleChildReaper.isAutoLoop("/usr/bin/python3 -m claude_swap list --json"))
        #expect(!StaleChildReaper.isAutoLoop("/usr/sbin/automount"))
    }

    final class Signals: @unchecked Sendable {
        var sent: [Int32] = []
        var alive = true
    }

    @Test func reaperTermsThenKills() {
        let s = Signals()
        let reaper = StaleChildReaper(commandLine: { _ in "python3 -m claude_swap auto --json" },
                                      signal: { _, sig in s.sent.append(sig) },
                                      isAlive: { _ in s.alive }, sleep: { _ in })
        #expect(reaper.reap(99))
        #expect(s.sent == [SIGTERM, SIGKILL])
    }

    @Test func reaperStopsAfterGracefulExit() {
        let s = Signals()
        let reaper = StaleChildReaper(commandLine: { _ in "cswap auto" },
                                      signal: { _, sig in s.sent.append(sig); s.alive = false },
                                      isAlive: { _ in s.alive }, sleep: { _ in })
        #expect(reaper.reap(99))
        #expect(s.sent == [SIGTERM])
    }

    @Test func reaperLeavesUnrelatedProcesses() {
        let s = Signals()
        let reaper = StaleChildReaper(commandLine: { _ in "/usr/bin/vim notes.txt" },
                                      signal: { _, sig in s.sent.append(sig) },
                                      isAlive: { _ in true }, sleep: { _ in })
        #expect(!reaper.reap(99))
        #expect(s.sent.isEmpty)
    }
}

/// Fake `cswap` executables in a temp dir, standing in for the core.
struct FakeCore {
    let dir: URL

    init(script: String) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("csb-core-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try ("#!/bin/bash\n" + script).write(to: executable, atomically: true, encoding: .utf8)
        chmod(executable.path, 0o755)
    }

    var executable: URL { dir.appendingPathComponent("cswap") }
    var command: CoreCommand { CoreCommand(executable: executable, prefix: []) }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

@Suite("Supervisor process lifecycle", .serialized)
@MainActor
struct SupervisorProcessTests {
    @Test func runsOneChildParsesEventsAndStops() async throws {
        let core = try FakeCore(script: """
        trap 'exit 0' TERM
        echo '{"schemaVersion":1,"event":"sleep","ts":"2026-11-05T09:31:00Z","seconds":60,"until":"2026-11-05T09:32:00Z"}'
        while true; do sleep 0.2; done
        """)
        defer { core.cleanup() }
        let lock = SupervisorLock(directory: core.dir.appendingPathComponent("state"))
        let sup = AutoSupervisor(command: core.command, lock: lock)
        var events: [AutoEvent] = []
        sup.onEvent = { ev, _ in events.append(ev) }
        sup.start()
        guard case .running(let pid, _) = sup.state else { Issue.record("not running: \(sup.state)"); return }
        #expect(lock.readPID() == pid)
        // A second supervisor on the same lock directory must not start.
        let other = AutoSupervisor(command: core.command, lock: SupervisorLock(directory: lock.directory))
        other.start()
        #expect(other.state == .blocked)
        for _ in 0..<50 where events.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        #expect(events.count == 1)
        sup.stop()
        #expect(sup.state == .stopped)
        // The pidfile names the child until it has exited.
        await waitUntil { lock.readPID() == nil }
        #expect(kill(pid, 0) != 0)
        #expect(lock.readPID() == nil)
    }

    @Test func startReapsAStaleChildFromThePidfile() async throws {
        let core = try FakeCore(script: "trap 'exit 0' TERM\nwhile true; do sleep 0.2; done\n")
        defer { core.cleanup() }
        // A leftover loop from a crashed app run, recorded in the pidfile.
        let stale = Process()
        stale.executableURL = core.executable
        stale.arguments = ["auto", "--json"]
        try stale.run()
        let lock = SupervisorLock(directory: core.dir.appendingPathComponent("state"))
        try FileManager.default.createDirectory(at: lock.directory, withIntermediateDirectories: true)
        lock.writePID(stale.processIdentifier)
        let sup = AutoSupervisor(command: core.command, lock: lock)
        sup.start()
        defer { sup.stop() }
        // The reap runs off the main actor; the new child starts after it.
        await waitUntil { if case .running = sup.state { return true }; return false }
        #expect(!stale.isRunning)
        guard case .running(let pid, _) = sup.state else { Issue.record("not running"); return }
        #expect(pid != stale.processIdentifier)
    }

    @Test func restartReplacesTheChildOnce() async throws {
        let core = try FakeCore(script: "trap 'exit 0' TERM\nwhile true; do sleep 0.2; done\n")
        defer { core.cleanup() }
        let sup = AutoSupervisor(command: core.command, lock: SupervisorLock(directory: core.dir.appendingPathComponent("state")))
        sup.start()
        defer { sup.stop() }
        guard case .running(let first, _) = sup.state else { Issue.record("not running"); return }
        sup.restart()
        var second: pid_t?
        for _ in 0..<60 {
            if case .running(let p, _) = sup.state { second = p; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(second != nil && second != first)
        #expect(kill(first, 0) != 0)
    }

    @Test func childExitingOnItsOwnReleasesItsOutput() async throws {
        let core = try FakeCore(script: """
        echo '{"schemaVersion":1,"event":"sleep","ts":"2026-11-05T09:31:00Z","seconds":60}'
        exit 3
        """)
        defer { core.cleanup() }
        let sup = AutoSupervisor(command: core.command, lock: SupervisorLock(directory: core.dir.appendingPathComponent("state")))
        var events = 0
        sup.onEvent = { _, _ in events += 1 }
        sup.start()
        defer { sup.stop() }
        await waitUntil { if case .restarting = sup.state { return true }; return false }
        // A readability handler left installed at EOF fires nonstop.
        await waitUntil { sup.openOutputs == 0 }
        #expect(sup.openOutputs == 0)
        #expect(events == 1)
    }

    /// Logs "<pid> start|term|exit"; on SIGTERM it lingers a second, like a loop mid-switch.
    private func slowCore() throws -> FakeCore {
        try FakeCore(script: """
        log="$(dirname "$0")/calls"
        echo "$$ start" >> "$log"
        trap 'echo "$$ term" >> "$log"; sleep 1; echo "$$ exit" >> "$log"; exit 0' TERM
        while true; do sleep 0.1; done
        """)
    }

    private func calls(_ core: FakeCore) -> [String] {
        ((try? String(contentsOf: core.dir.appendingPathComponent("calls"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map { String($0.split(separator: " ")[1]) }
    }

    @Test func offThenOnWaitsForTheOldChild() async throws {
        let core = try slowCore()
        defer { core.cleanup() }
        let lock = SupervisorLock(directory: core.dir.appendingPathComponent("state"))
        let sup = AutoSupervisor(command: core.command, lock: lock)
        sup.start()
        guard case .running(let first, _) = sup.state else { Issue.record("not running"); return }
        await waitUntil { calls(core) == ["start"] }
        sup.stop()
        sup.start()
        // The old loop still runs: it keeps the pidfile and no second one starts.
        #expect(lock.readPID() == first)
        await waitUntil { if case .running(let p, _) = sup.state { return p != first }; return false }
        await waitUntil { calls(core).count == 4 }
        #expect(calls(core) == ["start", "term", "exit", "start"])
        sup.stop()
        await waitUntil { lock.readPID() == nil }
    }

    @Test func rapidRestartsCoalesceAndWaitForTheOldChild() async throws {
        let core = try slowCore()
        defer { core.cleanup() }
        let sup = AutoSupervisor(command: core.command, lock: SupervisorLock(directory: core.dir.appendingPathComponent("state")))
        sup.restartDebounce = 0.3
        sup.start()
        guard case .running(let first, _) = sup.state else { Issue.record("not running"); return }
        await waitUntil { calls(core) == ["start"] }
        sup.restart()
        try await Task.sleep(for: .milliseconds(100))
        sup.restart()
        try await Task.sleep(for: .milliseconds(600))
        // The old loop is mid-shutdown: a further restart must not SIGKILL it.
        sup.restart()
        await waitUntil { if case .running(let p, _) = sup.state { return p != first }; return false }
        try await Task.sleep(for: .milliseconds(500))
        #expect(calls(core) == ["start", "term", "exit", "start"])
        sup.stop()
        await waitUntil { sup.openOutputs == 0 && calls(core).last == "exit" }
    }

    @Test func shutdownWaitsAndKeepsTheFinalEvent() throws {
        let line = #"{"schemaVersion":1,"event":"switch","trigger":"threshold"}"#
        let core = try FakeCore(script: """
        trap 'sleep 0.5; echo '"'"'\(line)'"'"'; exit 0' TERM
        touch "$0.ready"
        while true; do sleep 0.1; done
        """)
        defer { core.cleanup() }
        let lock = SupervisorLock(directory: core.dir.appendingPathComponent("state"))
        let sup = AutoSupervisor(command: core.command, lock: lock)
        var events: [AutoEvent] = []
        sup.onEvent = { ev, _ in events.append(ev) }
        sup.start()
        guard case .running(let pid, _) = sup.state else { Issue.record("not running"); return }
        // TERM only after the trap is set: a fresh script can take a while to start.
        let ready = core.executable.path + ".ready"
        let deadline = Date().addingTimeInterval(8)
        while !FileManager.default.fileExists(atPath: ready) && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        sup.shutdown()
        #expect(kill(pid, 0) != 0)
        #expect(lock.readPID() == nil)
        guard case .switched(let s)? = events.first, events.count == 1 else {
            Issue.record("events: \(events)")
            return
        }
        #expect(s.trigger == "threshold")
    }
}

@MainActor
func waitUntil(timeout: Duration = .seconds(8), _ condition: () -> Bool) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() && clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(50))
    }
}

@Suite("CoreClient against a fake core", .serialized)
struct CoreClientTests {
    @Test func olderCoreFallsBackToPlainList() async throws {
        let list = String(decoding: try fixture("list-rich.json"), as: UTF8.self)
        let core = try FakeCore(script: """
        for a in "$@"; do
          if [ "$a" = "--no-fetch" ] || [ "$a" = "--refresh" ]; then
            echo "cswap: error: unrecognized arguments: $a" >&2; exit 2
          fi
        done
        cat <<'JSON'
        \(list)
        JSON
        """)
        defer { core.cleanup() }
        let client = CoreClient(command: core.command, environment: CoreEnvironment.make())
        let p = try await client.list(.noFetch)
        #expect(p.accounts.count == 5)
        #expect(await client.listFlagsUnsupported)
    }

    @Test func refreshAllNeverFallsBackToAPlainList() async throws {
        let core = try FakeCore(script: """
        echo "$*" >> "$(dirname "$0")/calls"
        echo "cswap: error: unrecognized arguments: --refresh-all" >&2; exit 2
        """)
        defer { core.cleanup() }
        let client = CoreClient(command: core.command, environment: CoreEnvironment.make())
        do {
            _ = try await client.list(.refreshAll)
            Issue.record("expected an error")
        } catch let e as CoreError {
            #expect(e.isUnsupportedFlag)
        }
        let calls = try String(contentsOf: core.dir.appendingPathComponent("calls"), encoding: .utf8)
        #expect(calls == "list --json --refresh-all\n")
        #expect(await !client.listFlagsUnsupported)
    }

    @Test func refreshButtonModeFollowsIgnoreDisabled() async throws {
        let list = String(decoding: try fixture("list-rich.json"), as: UTF8.self)
        let core = try FakeCore(script: """
        echo "$*" >> "$(dirname "$0")/calls"
        cat <<'JSON'
        \(list)
        JSON
        """)
        defer { core.cleanup() }
        let client = CoreClient(command: core.command, environment: CoreEnvironment.make())
        _ = try await client.list(.refresh(ignoringDisabled: false))
        _ = try await client.list(.refresh(ignoringDisabled: true))
        let calls = try String(contentsOf: core.dir.appendingPathComponent("calls"), encoding: .utf8)
        #expect(calls == "list --json --refresh-all\nlist --json --refresh\n")
    }

    @Test func refreshAllPassesItsFlag() async throws {
        let list = String(decoding: try fixture("list-rich.json"), as: UTF8.self)
        let core = try FakeCore(script: """
        [ "$3" = "--refresh-all" ] || exit 9
        cat <<'JSON'
        \(list)
        JSON
        """)
        defer { core.cleanup() }
        let client = CoreClient(command: core.command, environment: CoreEnvironment.make())
        #expect(try await client.list(.refreshAll).accounts.count == 5)
    }

    @Test func errorEnvelopeSurfaces() async throws {
        let core = try FakeCore(script: """
        echo '{"schemaVersion":1,"error":{"type":"ClaudeSwitchError","message":"Account 9 not found"}}'
        exit 1
        """)
        defer { core.cleanup() }
        let client = CoreClient(command: core.command, environment: CoreEnvironment.make())
        await #expect(throws: CoreError.failed(status: 1, message: "Account 9 not found", type: "ClaudeSwitchError")) {
            try await client.switchTo(9)
        }
    }

    @Test func writesRunOneAtATimeInOrder() async throws {
        let core = try FakeCore(script: """
        log="$(dirname "$0")/calls"
        echo "start $*" >> "$log"; sleep 0.3; echo "end $*" >> "$log"
        """)
        defer { core.cleanup() }
        let client = CoreClient(command: core.command, environment: CoreEnvironment.make())
        async let a: Void = client.setEnabled(2, false)
        try await Task.sleep(for: .milliseconds(50))
        async let b: Void = client.configSet("autoswitch.threshold", "85")
        _ = try await (a, b)
        let calls = try String(contentsOf: core.dir.appendingPathComponent("calls"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(calls == ["start disable 2", "end disable 2",
                          "start config set autoswitch.threshold 85", "end config set autoswitch.threshold 85"])
    }

    @Test func headerProbeIsNeverWritten() async throws {
        let core = try FakeCore(script: "echo \"$*\" >> \"$(dirname \"$0\")/calls\"\n")
        defer { core.cleanup() }
        let client = CoreClient(command: core.command, environment: CoreEnvironment.make())
        try await client.configSet("usage.headerProbe", "false")
        try await client.configUnset("usage.headerProbe")
        #expect(!FileManager.default.fileExists(atPath: core.dir.appendingPathComponent("calls").path))
    }

    @Test func timeoutKillsTheChild() async throws {
        let core = try FakeCore(script: "sleep 30\n")
        defer { core.cleanup() }
        await #expect(throws: CoreError.timeout(seconds: 0.5)) {
            _ = try await ProcessRunner.run(core.executable, [], environment: CoreEnvironment.make(), timeout: 0.5)
        }
    }

    @Test func timeoutFiresWhileAGrandchildHoldsThePipes() async throws {
        // The child exits at once; the background sleep keeps stdout open.
        let core = try FakeCore(script: "sleep 30 &\necho $! > \"$(dirname \"$0\")/grandchild\"\nexit 0\n")
        defer {
            if let s = try? String(contentsOf: core.dir.appendingPathComponent("grandchild"), encoding: .utf8),
               let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGKILL) }
            core.cleanup()
        }
        await #expect(throws: CoreError.timeout(seconds: 0.5)) {
            _ = try await ProcessRunner.run(core.executable, [], environment: CoreEnvironment.make(), timeout: 0.5)
        }
    }

    @Test func environmentIsLaunchdSafe() {
        let env = CoreEnvironment.make(from: ["HTTPS_PROXY": "http://p:1", "SECRET": "x"], home: "/Users/x")
        #expect(env["PATH"] == "/Users/x/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(env["HTTPS_PROXY"] == "http://p:1")
        #expect(env["SECRET"] == nil)
        #expect(env["HOME"] == "/Users/x")
    }
}

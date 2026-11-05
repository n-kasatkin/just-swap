import Foundation
import Testing
@testable import JustSwapCore

/// Every account change, end to end through `CoreClient` and the real
/// vendored core, against a throwaway store.
///
/// Isolation: HOME is a fresh temporary directory; the core runs as on Linux
/// (`sys.platform = "linux"` before it is imported), so credentials are files
/// under that HOME and no code path picks the macOS Keychain; a guard refuses
/// to start any `security` process and `keyring` cannot be imported; the
/// proxy variables point at a closed port, so nothing reaches the network.
/// The test checks the real store's files are untouched afterwards.
@Suite("Account changes against an isolated real core", .serialized,
       .enabled(if: BuiltApp.hasPython, "build the app first (scripts/build.sh): the test needs its bundled Python"))
struct IsolatedCoreTests {
    static let repo = BuiltApp.repo

    static let launcher = """
    import os, subprocess, sys
    _popen_init = subprocess.Popen.__init__
    def _guarded(self, args, *a, **k):
        first = args if isinstance(args, (str, bytes)) else (list(args) or [""])[0]
        if os.path.basename(os.fsdecode(first)).startswith("security"):
            raise RuntimeError("keychain access is blocked in the isolated core")
        return _popen_init(self, args, *a, **k)
    subprocess.Popen.__init__ = _guarded
    sys.modules["keyring"] = None
    sys.platform = "linux"
    from claude_swap.cli import main
    sys.argv[0] = "cswap"
    main()
    """


    struct Sandbox {
        let home: URL
        let client: CoreClient

        init() throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("csb-iso-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
            var env = CoreEnvironment.make(from: [:], home: home.path)
            env["PYTHONPATH"] = IsolatedCoreTests.repo.appendingPathComponent("vendor/claude-swap/src").path
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            for k in ["https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY"] { env[k] = "http://127.0.0.1:9" }
            env["NO_PROXY"] = ""
            env["no_proxy"] = ""
            env["TMPDIR"] = home.path + "/"
            // -B no .pyc, -P no cwd on sys.path (the runner's cwd is the real home), -s no user site.
            let command = CoreCommand(executable: BuiltApp.python,
                                      prefix: ["-B", "-P", "-s", "-c", IsolatedCoreTests.launcher])
            client = CoreClient(command: command, environment: env)
        }

        var store: URL { home.appendingPathComponent(".local/share/claude-swap") }
        func cleanup() { try? FileManager.default.removeItem(at: home) }
    }

    /// Modification dates of the real store's account files, to prove they did
    /// not change. Only files that account changes write: the running Claude
    /// Code rewrites ~/.claude.json and the real autoswitch loop the usage cache.
    static func realStoreStamp() -> [String: Date] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var out: [String: Date] = [:]
        for rel in [".claude-swap-backup", ".claude-swap-backup/sequence.json", ".claude-swap-backup/mappings.json",
                    ".claude-swap-backup/settings.json", ".local/share/claude-swap"] {
            let p = home.appendingPathComponent(rel).path
            if let d = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date { out[rel] = d }
        }
        return out
    }

    @Test func everyAccountChangeRoundTrips() async throws {
        let before = Self.realStoreStamp()
        let box = try Sandbox()
        defer { box.cleanup() }
        let c = box.client

        // Isolation first: an empty store, created under the temporary HOME only.
        #expect(try await c.list(.noFetch).accounts.isEmpty)

        try await c.perform(.addToken(token: "sk-ant-oat01-alpha-test-token", slot: nil, email: "alpha@example.com"))
        #expect(FileManager.default.fileExists(atPath: box.store.appendingPathComponent("sequence.json").path))
        try await c.perform(.addToken(token: "sk-ant-api03-beta-test-key", slot: nil, email: "beta@example.com"))
        try await c.perform(.addToken(token: "sk-ant-oat01-gamma-test-token", slot: nil, email: nil))
        var rows = try await c.list(.noFetch).accounts
        #expect(rows.map(\.number) == [1, 2, 3])
        #expect(rows.map(\.email).prefix(2) == ["alpha@example.com", "beta@example.com"])

        try await c.perform(.setAlias(slot: 1, alias: "alpha"))
        try await c.perform(.setThreshold(slot: 1, percent: 85))
        try await c.perform(.setPriority(slot: 2, tier: 3))
        try await c.perform(.setEnabled(slot: 3, enabled: false))
        rows = try await c.list(.noFetch).accounts
        #expect(rows[0].alias == "alpha" && rows[0].threshold == 85)
        #expect(rows[1].priority == 3)
        #expect(!rows[2].isEnabled)

        try await c.perform(.setAlias(slot: 1, alias: nil))
        try await c.perform(.setThreshold(slot: 1, percent: nil))
        try await c.perform(.setPriority(slot: 2, tier: 0))
        try await c.perform(.setEnabled(slot: 3, enabled: true))
        rows = try await c.list(.noFetch).accounts
        #expect(rows[0].alias == nil && rows[0].threshold == nil && rows[1].priority == nil && rows[2].isEnabled)

        // Drag slot 1 onto slot 3: the others shift up by one.
        for m in ReorderPlan.moves(slots: [1, 2, 3], from: 1, to: 3) { try await c.perform(m) }
        rows = try await c.list(.noFetch).accounts.sorted { $0.number < $1.number }
        #expect(rows.map(\.email)[0...2] == ["beta@example.com", rows[1].email, "alpha@example.com"])
        try await c.perform(.swap(1, 3))
        rows = try await c.list(.noFetch).accounts.sorted { $0.number < $1.number }
        #expect(rows[0].email == "alpha@example.com" && rows[2].email == "beta@example.com")

        // Directory mappings.
        let proj = box.home.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try await c.perform(.map(slot: 1, path: proj.path))
        let maps = try await c.mappings().mappings
        #expect(maps.count == 1 && maps[0].slot == 1 && maps[0].email == "alpha@example.com")
        try await c.perform(.unmap(path: proj.path))
        #expect(try await c.mappings().mappings.isEmpty)

        #expect(try await c.unclaimed().entries.isEmpty)

        // Export, remove, import back.
        let file = box.home.appendingPathComponent("export.json")
        try await c.perform(.export(path: file.path))
        #expect(FileManager.default.fileExists(atPath: file.path))
        try await c.perform(.remove(slot: 3))
        #expect(try await c.list(.noFetch).accounts.count == 2)
        try await c.perform(.importAccounts(path: file.path, overwrite: false))
        #expect(try await c.list(.noFetch).accounts.count == 3)

        // Replace a slot's token, keeping its email: the slot's settings stay.
        try await c.perform(.setAlias(slot: 1, alias: "alpha"))
        try await c.perform(.setThreshold(slot: 1, percent: 85))
        try await c.perform(.setPriority(slot: 1, tier: 3))
        try await c.perform(.setEnabled(slot: 1, enabled: false))
        try await c.perform(.addToken(token: "sk-ant-oat01-alpha-new-token", slot: 1, email: "alpha@example.com"))
        rows = try await c.list(.noFetch).accounts.sorted { $0.number < $1.number }
        #expect(rows[0].email == "alpha@example.com")
        #expect(rows[0].alias == "alpha" && rows[0].threshold == 85 && rows[0].priority == 3 && !rows[0].isEnabled)

        // Import usage: another machine's list output.
        let usage = box.home.appendingPathComponent("usage.json")
        let listed = try await c.run(["list", "--json", "--no-fetch"])
        try listed.stdout.write(to: usage)
        try await c.perform(.importUsage(path: usage.path))

        // A refused change reports the core's own line.
        await #expect(throws: CoreError.failed(status: 1, message: "Account-9 does not exist", type: nil)) {
            try await c.perform(.setAlias(slot: 9, alias: "nine"))
        }

        // One slot's probe runs (and fails offline) without failing the list.
        #expect(try await c.refreshSlot(2).accounts.count == 3)

        try await c.perform(.purgeAll)
        #expect(try await c.list(.noFetch).accounts.isEmpty)

        #expect(Self.realStoreStamp() == before)
    }
}

/// The built app in build/: its bundled interpreter carries the core's
/// dependencies; the core itself comes from vendor/claude-swap/src.
enum BuiltApp {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let python = repo.appendingPathComponent("build/just swap.app/Contents/Resources/python/bin/python3")
    static var hasPython: Bool { FileManager.default.isExecutableFile(atPath: python.path) }
}

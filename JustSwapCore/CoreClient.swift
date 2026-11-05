import Foundation

/// How to start the claude-swap core: an executable plus fixed leading args.
public struct CoreCommand: Sendable, Equatable {
    public var executable: URL
    public var prefix: [String]

    public init(executable: URL, prefix: [String]) {
        self.executable = executable
        self.prefix = prefix
    }

    /// Resolution order: the `CSWAP_PATH` user default or env var (debugging),
    /// the Python embedded in the app bundle, then `cswap` in `~/.local/bin`
    /// (unbundled Debug builds).
    public static func resolve(bundle: Bundle = .main, defaults: UserDefaults = .standard,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> CoreCommand {
        let override = defaults.string(forKey: "CSWAP_PATH") ?? environment["CSWAP_PATH"]
        if let override, !override.isEmpty {
            return CoreCommand(executable: URL(fileURLWithPath: (override as NSString).expandingTildeInPath), prefix: [])
        }
        if let res = bundle.resourceURL {
            let python = res.appendingPathComponent("python/bin/python3")
            if FileManager.default.isExecutableFile(atPath: python.path) {
                // -I: isolated (no user site, no PYTHON* env); -B: never write
                // .pyc into the signed bundle.
                return CoreCommand(executable: python, prefix: ["-I", "-B", "-m", "claude_swap"])
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return CoreCommand(executable: URL(fileURLWithPath: home + "/.local/bin/cswap"), prefix: [])
    }
}

public enum CoreEnvironment {
    /// launchd's default PATH lacks Homebrew and ~/.local/bin, where `claude`
    /// lives; the core shells out to find running sessions (mirrors
    /// `launch_agent.py` `_EXTRA_PATH_DIRS` + `_BASE_PATH_DIRS`).
    public static func path(home: String) -> String {
        ([home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
    }

    static let forwardedKeys = [
        "https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY",
        "no_proxy", "NO_PROXY", "SSL_CERT_FILE", "SSL_CERT_DIR",
    ]

    public static func make(from env: [String: String] = ProcessInfo.processInfo.environment,
                            home: String = NSHomeDirectory()) -> [String: String] {
        var out: [String: String] = [
            "HOME": home,
            "PATH": path(home: home),
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "PYTHONIOENCODING": "utf-8",
            "NO_COLOR": "1",
            "TERM": "dumb",
        ]
        for key in ["USER", "LOGNAME", "TMPDIR"] + forwardedKeys {
            if let v = env[key] { out[key] = v }
        }
        return out
    }
}

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data

    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

public enum CoreError: Error, LocalizedError, Equatable {
    case launch(String)
    case timeout(seconds: Double)
    case failed(status: Int32, message: String, type: String?)
    case decode(String)

    public var errorDescription: String? {
        switch self {
        case .launch(let m): return "Could not start the core: \(m)"
        case .timeout(let s): return "The core did not answer in \(Int(s)) s"
        case .failed(_, let m, _): return m
        case .decode(let m): return "Unexpected core output: \(m)"
        }
    }

    /// argparse rejected a flag: the embedded core predates it.
    public var isUnsupportedFlag: Bool {
        if case .failed(_, let m, _) = self { return m.lowercased().contains("unrecognized arguments") }
        return false
    }

    /// Maps a failed run to an error: the JSON error envelope on stdout when
    /// the core printed one, else the last non-empty stderr line without the
    /// core's "Error: " or argparse's "<prog>: error: " prefix.
    public static func from(_ r: ProcessResult) -> CoreError {
        if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: r.stdout) {
            return .failed(status: r.status, message: env.error.message, type: env.error.type)
        }
        let line = r.stderrText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        return .failed(status: r.status, message: line.map(cleanMessage) ?? "exit status \(r.status)", type: nil)
    }

    static func cleanMessage(_ line: String) -> String {
        var m = line
        if let r = m.range(of: ": error: "), !m[..<r.lowerBound].contains(":") {
            m = String(m[r.upperBound...])
        }
        for prefix in ["Error: ", "error: "] where m.hasPrefix(prefix) {
            m = String(m.dropFirst(prefix.count))
        }
        guard let first = m.first else { return line }
        return first.uppercased() + m.dropFirst()
    }

    /// A write's outcome: a non-zero exit is an error; so is exit 0 with the
    /// core's "Cancelled" (a prompt it could not get a yes for).
    public static func checkWrite(_ r: ProcessResult) throws {
        guard r.status == 0 else { throw from(r) }
        let out = String(decoding: r.stdout, as: UTF8.self)
        if out.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces) == "Cancelled" }) {
            throw CoreError.failed(status: 0, message: "The core cancelled the change", type: nil)
        }
    }
}

/// Runs one process to completion, draining both pipes concurrently, and
/// terminates it after `timeout`.
public enum ProcessRunner {
    /// Resumes the continuation exactly once: either the normal completion
    /// or the timeout, whichever comes first. A timed-out child may leave a
    /// grandchild holding the pipes, so the timeout path does not wait for EOF.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        var out = Data()

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    public static func run(_ executable: URL, _ args: [String], environment: [String: String],
                           timeout: TimeInterval, stdin: String? = nil) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = executable
                p.arguments = args
                p.environment = environment
                p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
                let outPipe = Pipe(), errPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = errPipe
                let inPipe = stdin.map { _ in Pipe() }
                p.standardInput = inPipe ?? FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(throwing: CoreError.launch(error.localizedDescription))
                    return
                }
                if let inPipe, let stdin {
                    // A few hundred bytes at most: fits the pipe buffer, so the write never blocks.
                    // A core that exits before reading closes the pipe: the write then fails with
                    // EPIPE (ignored here) instead of a SIGPIPE that would kill the app.
                    _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                    try? inPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
                    try? inPipe.fileHandleForWriting.close()
                }
                let once = Once()
                // Fires even when the child already exited but a grandchild
                // still holds the pipes; SIGTERM, then SIGKILL 3 s later.
                let killer = DispatchWorkItem {
                    guard once.claim() else { return }
                    if p.isRunning {
                        p.terminate()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                        }
                    }
                    cont.resume(throwing: CoreError.timeout(seconds: timeout))
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    once.out = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let err = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                killer.cancel()
                if once.claim() {
                    cont.resume(returning: ProcessResult(status: p.terminationStatus, stdout: once.out, stderr: err))
                }
            }
        }
    }
}

/// The app's only door into the core. Reads run concurrently; writes
/// (switch, enable, config set …) run one at a time, in call order.
public actor CoreClient {
    public enum ListMode: Sendable {
        /// Stored values only.
        case noFetch
        /// Probe every enabled slot and the active one now.
        case refresh
        /// Probe every slot, disabled and dead-token ones included.
        case refreshAll
        /// The core's paced read (fetches only stale, poll-due slots).
        case paced

        /// The Refresh button: every slot, or with "Ignore disabled" the
        /// enabled ones and the active one.
        public static func refresh(ignoringDisabled: Bool) -> ListMode {
            ignoringDisabled ? .refresh : .refreshAll
        }
    }

    public nonisolated let command: CoreCommand
    private let environment: [String: String]
    private var writeTail: Task<Void, Never>?
    /// Set once the core rejects `--no-fetch`/`--refresh` (older core).
    public private(set) var listFlagsUnsupported = false

    public init(command: CoreCommand = .resolve(), environment: [String: String] = CoreEnvironment.make()) {
        self.command = command
        self.environment = environment
    }

    public func run(_ args: [String], timeout: TimeInterval = 60, stdin: String? = nil) async throws -> ProcessResult {
        try await ProcessRunner.run(command.executable, command.prefix + args, environment: environment,
                                    timeout: timeout, stdin: stdin)
    }

    private func json<T: Decodable>(_ type: T.Type, _ args: [String], timeout: TimeInterval) async throws -> T {
        let r = try await run(args, timeout: timeout)
        guard r.status == 0 else { throw CoreError.from(r) }
        do {
            return try JSONDecoder().decode(T.self, from: r.stdout)
        } catch {
            throw CoreError.decode(String(describing: error))
        }
    }

    public func list(_ mode: ListMode) async throws -> ListPayload {
        var args = ["list", "--json"]
        switch mode {
        case .noFetch where !listFlagsUnsupported: args.append("--no-fetch")
        case .refresh where !listFlagsUnsupported: args.append("--refresh")
        // No stand-in exists for probing disabled slots: an older core reports the error.
        case .refreshAll: args.append("--refresh-all")
        default: break
        }
        // A forced probe of every slot can take a while; stored reads are quick.
        let timeout: TimeInterval = (mode == .refresh || mode == .refreshAll) ? 180 : 60
        do {
            return try await json(ListPayload.self, args, timeout: timeout)
        } catch let e as CoreError where e.isUnsupportedFlag && args.count > 2 && mode != .refreshAll {
            // Older core: plain `list --json`, the paced read the old menu bar used.
            listFlagsUnsupported = true
            return try await json(ListPayload.self, ["list", "--json"], timeout: timeout)
        }
    }

    public func mappings() async throws -> MappingsPayload {
        try await json(MappingsPayload.self, AccountListing.mappings.args, timeout: AccountListing.mappings.timeout)
    }

    public func unclaimed() async throws -> UnclaimedPayload {
        try await json(UnclaimedPayload.self, AccountListing.unclaimed.args, timeout: AccountListing.unclaimed.timeout)
    }

    /// Probes one slot now, disabled ones included, and returns the whole list.
    public func refreshSlot(_ slot: Int) async throws -> ListPayload {
        let inv = AccountListing.refreshSlot(slot)
        return try await json(ListPayload.self, inv.args, timeout: inv.timeout)
    }

    public func config() async throws -> ConfigPayload {
        try await json(ConfigPayload.self, ["config", "list", "--json"], timeout: 30)
    }

    public func version() async throws -> String {
        let r = try await run(["--version"], timeout: 30)
        guard r.status == 0 else { throw CoreError.from(r) }
        return String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: writes

    public func switchTo(_ number: Int) async throws {
        try await perform(.switchTo(slot: number))
    }

    public func setEnabled(_ number: Int, _ enabled: Bool) async throws {
        try await perform(.setEnabled(slot: number, enabled: enabled))
    }

    public func perform(_ command: AccountCommand) async throws {
        let inv = command.invocation
        try await write(inv.args, stdin: inv.stdin, timeout: inv.timeout)
    }

    public func configSet(_ key: String, _ value: String) async throws {
        guard key != "usage.headerProbe" else { return }
        try await write(["config", "set", key, value])
    }

    public func configUnset(_ key: String) async throws {
        guard key != "usage.headerProbe" else { return }
        try await write(["config", "unset", key])
    }

    private func write(_ args: [String], stdin: String? = nil, timeout: TimeInterval = 60) async throws {
        let previous = writeTail
        let task = Task { () -> Result<Void, Error> in
            await previous?.value
            do {
                let r = try await self.run(args, timeout: timeout, stdin: stdin)
                try CoreError.checkWrite(r)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        writeTail = Task { _ = await task.value }
        try await task.value.get()
    }
}

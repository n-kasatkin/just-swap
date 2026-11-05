import Darwin
import Foundation

/// Singleton guard for the autoswitch child: an flock held for the app's
/// lifetime plus a pidfile naming the child, both in Application Support.
/// The flock keeps a second app instance from supervising; the pidfile lets
/// a restarted app find and stop a child orphaned by a crash or `kill -9`.
public final class SupervisorLock: @unchecked Sendable {
    public let directory: URL
    private var fd: Int32 = -1

    public init(directory: URL) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("just swap", isDirectory: true)
    }

    public var lockURL: URL { directory.appendingPathComponent("auto.lock") }
    public var pidURL: URL { directory.appendingPathComponent("auto.pid") }
    public var isHeld: Bool { fd >= 0 }

    /// Non-blocking; false while another holder (process or open file) has it.
    public func acquire() -> Bool {
        if fd >= 0 { return true }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let f = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard f >= 0 else { return false }
        if flock(f, LOCK_EX | LOCK_NB) != 0 {
            close(f)
            return false
        }
        fd = f
        return true
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }

    public func readPID() -> pid_t? {
        guard let s = try? String(contentsOf: pidURL, encoding: .utf8),
              let n = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)), n > 0 else { return nil }
        return n
    }

    public func writePID(_ pid: pid_t) {
        try? "\(pid)\n".write(to: pidURL, atomically: true, encoding: .utf8)
    }

    public func clearPID() {
        try? FileManager.default.removeItem(at: pidURL)
    }
}

/// Stops an autoswitch child left behind by a previous app run. Only a
/// process whose command line is a claude-swap `auto` loop is touched, so a
/// recycled pid of an unrelated process survives.
public struct StaleChildReaper: Sendable {
    public var commandLine: @Sendable (pid_t) -> String?
    public var signal: @Sendable (pid_t, Int32) -> Void
    public var isAlive: @Sendable (pid_t) -> Bool
    public var sleep: @Sendable (TimeInterval) -> Void

    public init(commandLine: @escaping @Sendable (pid_t) -> String? = StaleChildReaper.psCommandLine,
                signal: @escaping @Sendable (pid_t, Int32) -> Void = { _ = kill($0, $1) },
                isAlive: @escaping @Sendable (pid_t) -> Bool = { kill($0, 0) == 0 },
                sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.commandLine = commandLine
        self.signal = signal
        self.isAlive = isAlive
        self.sleep = sleep
    }

    public static func isAutoLoop(_ cmd: String) -> Bool {
        let parts = cmd.split(separator: " ").map(String.init)
        guard let i = parts.firstIndex(where: { $0 == "claude_swap" || $0.hasSuffix("/cswap") || $0 == "cswap" }) else {
            return false
        }
        return parts[(i + 1)...].contains("auto")
    }

    /// SIGTERM, up to 3 s grace, then SIGKILL. Returns true if a stale child was stopped.
    @discardableResult
    public func reap(_ pid: pid_t) -> Bool {
        guard isAlive(pid), let cmd = commandLine(pid), Self.isAutoLoop(cmd) else { return false }
        signal(pid, SIGTERM)
        for _ in 0..<30 {
            if !isAlive(pid) { return true }
            sleep(0.1)
        }
        signal(pid, SIGKILL)
        return true
    }

    public static let psCommandLine: @Sendable (pid_t) -> String? = { pid in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "command=", "-p", String(pid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}

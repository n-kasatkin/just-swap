import Darwin
import Foundation

/// Restart delays for a crashing child: 2, 4, 8 … 60 s; a run that lasted a
/// minute counts as healthy and resets the sequence.
public struct RestartBackoff: Sendable, Equatable {
    public private(set) var failures = 0
    public var base: TimeInterval = 2
    public var cap: TimeInterval = 60
    public var healthyRun: TimeInterval = 60

    public init() {}

    public mutating func nextDelay(ranFor: TimeInterval) -> TimeInterval {
        if ranFor >= healthyRun { failures = 0 }
        let delay = min(base * pow(2, Double(failures)), cap)
        failures += 1
        return delay
    }
}

/// Splits a byte stream into lines, keeping a partial tail between chunks.
public struct LineBuffer: Sendable {
    private var pending = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...nl)
        }
        return lines
    }
}

/// Runs exactly one `cswap auto --json` child while enabled: parses its
/// JSONL, restarts it with backoff when it dies, and stops it on disable,
/// quit or a settings change. A new child is spawned only once the previous
/// one has exited: two engines never overlap.
@MainActor
public final class AutoSupervisor {
    public enum State: Equatable, Sendable {
        case stopped
        case running(pid: pid_t, since: Date)
        case restarting(at: Date)
        /// Another app instance holds the singleton lock.
        case blocked
        case failed(String)
    }

    /// Bytes read off a child's stdout, in read order, until EOF. The reader
    /// thread fills it; the main actor drains it, from a main-queue hop or
    /// directly during a blocking shutdown.
    final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var eof = false

        func put(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            if chunk.isEmpty { eof = true } else { data.append(chunk) }
        }

        func take() -> (data: Data, eof: Bool) {
            lock.lock()
            defer { lock.unlock() }
            let out = data
            data = Data()
            return (out, eof)
        }

        var atEOF: Bool {
            lock.lock()
            defer { lock.unlock() }
            return eof
        }
    }

    /// One spawned child. Each keeps its own line buffer and output, so lines
    /// it prints after SIGTERM (a final switch) are still parsed.
    @MainActor
    final class Child {
        let process: Process
        let output: FileHandle
        let inbox = Inbox()
        let startedAt = Date()
        var buffer = LineBuffer()
        /// SIGTERM sent: a stop, a restart or quit is under way.
        var stopping = false
        var exited = false
        var outputClosed = false
        var killTask: Task<Void, Never>?

        init(process: Process, output: FileHandle) {
            self.process = process
            self.output = output
        }

        var pid: pid_t { process.processIdentifier }
    }

    public private(set) var state: State = .stopped {
        didSet { onState?(state) }
    }
    public var onEvent: ((AutoEvent, String) -> Void)?
    public var onState: ((State) -> Void)?

    /// SIGTERM → SIGKILL grace on disable and quit.
    var stopGrace: TimeInterval = 5
    /// Longer on a settings change, so a switch in flight can finish.
    var restartGrace: TimeInterval = 30
    /// Rapid settings edits coalesce into one restart.
    var restartDebounce: TimeInterval = 1
    /// After exit, EOF normally follows at once; a grandchild holding the
    /// pipe would keep it open, so the output is dropped after this long.
    var eofGrace: TimeInterval = 2

    private let command: CoreCommand
    private let environment: [String: String]
    private let lock: SupervisorLock
    private let reaper: StaleChildReaper
    /// The latest child until it has exited, stopping or not.
    private var child: Child?
    private var wanted = false
    private var backoff = RestartBackoff()
    /// A pending backoff wait or debounced restart.
    private var restartTask: Task<Void, Never>?
    /// Stopping a loop left by a previous app run, off the main actor.
    private var reapTask: Task<Void, Never>?
    /// Output handles still watched (a handler left installed at EOF spins).
    private(set) var openOutputs = 0

    public init(command: CoreCommand, environment: [String: String] = CoreEnvironment.make(),
                lock: SupervisorLock = SupervisorLock(directory: SupervisorLock.defaultDirectory),
                reaper: StaleChildReaper = StaleChildReaper()) {
        self.command = command
        self.environment = environment
        self.lock = lock
        self.reaper = reaper
    }

    public var isEnabled: Bool {
        switch state {
        case .stopped, .blocked: return false
        default: return true
        }
    }

    public func start() {
        guard lock.acquire() else {
            wanted = false
            state = .blocked
            return
        }
        wanted = true
        if let c = child {
            // A child still shutting down respawns from its exit.
            if c.stopping { state = .restarting(at: Date()) }
            return
        }
        guard restartTask == nil, reapTask == nil else { return }
        backoff = RestartBackoff()
        guard let stale = lock.readPID() else {
            spawn()
            return
        }
        state = .restarting(at: Date())
        let reaper = self.reaper
        reapTask = Task { [weak self] in
            _ = await Task.detached { reaper.reap(stale) }.value
            guard let self else { return }
            self.reapTask = nil
            if self.lock.readPID() == stale { self.lock.clearPID() }
            if !self.wanted {
                if self.child == nil { self.lock.release() }
            } else if self.restartTask == nil {
                self.spawn()
            }
        }
    }

    /// SIGTERM the child and stay stopped. The pidfile and the lock are kept
    /// until the child has exited.
    public func stop() {
        wanted = false
        restartTask?.cancel()
        restartTask = nil
        if let c = child {
            terminate(c, grace: stopGrace)
        } else if reapTask == nil {
            lock.release()
        }
        state = .stopped
    }

    /// Settings changed: the child reads settings.json only at start.
    public func restart() {
        guard wanted else { return }
        restartTask?.cancel()
        state = .restarting(at: Date().addingTimeInterval(restartDebounce))
        let debounce = restartDebounce
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(debounce))
            guard !Task.isCancelled, let self else { return }
            self.restartTask = nil
            self.backoff = RestartBackoff()
            if let c = self.child {
                // Respawned from its exit; a child already stopping keeps its first deadline.
                self.terminate(c, grace: self.restartGrace)
            } else if self.reapTask == nil {
                self.spawn()
            }
        }
    }

    /// Wake the loop for an immediate poll (after a forced refresh).
    public func wake() {
        if let c = child, !c.stopping, c.process.isRunning { kill(c.pid, SIGUSR1) }
    }

    /// App quit: SIGTERM, up to `grace` for the loop to finish, then SIGKILL;
    /// output is read to EOF so a final switch event still lands. Blocks the
    /// main thread, so it never relies on main-queue hops: it polls the
    /// process and drains the inbox itself.
    public func shutdown(grace: TimeInterval = 5) {
        let c = child
        reapTask?.cancel()
        stop()
        guard let c else { return }
        func wait(_ seconds: TimeInterval, while busy: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while busy() && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        }
        wait(grace) { c.process.isRunning }
        if c.process.isRunning {
            kill(c.pid, SIGKILL)
            wait(1) { c.process.isRunning }
        }
        if !c.process.isRunning {
            exited(c, status: c.process.terminationStatus, reason: c.process.terminationReason)
        }
        wait(1) { !c.inbox.atEOF }
        drain(c)
        closeOutput(c)
    }

    private func terminate(_ c: Child, grace: TimeInterval) {
        guard !c.stopping else { return }
        c.stopping = true
        if c.process.isRunning { c.process.terminate() }
        let process = c.process
        c.killTask = Task {
            try? await Task.sleep(for: .seconds(grace))
            // Cancelled means it exited. The retained Process, not a bare pid,
            // tells whether this child is still there: a reaped pid may be reused.
            if !Task.isCancelled, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func spawn() {
        guard wanted, child == nil else { return }
        let p = Process()
        p.executableURL = command.executable
        p.arguments = command.prefix + ["auto", "--json"]
        p.environment = environment
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let c = Child(process: p, output: out.fileHandleForReading)
        let inbox = c.inbox
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            // At EOF the handler would fire nonstop.
            if data.isEmpty { h.readabilityHandler = nil }
            inbox.put(data)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.drain(c) } }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let reason = proc.terminationReason
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(c, status: status, reason: reason) } }
        }
        do {
            try p.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            state = .failed(error.localizedDescription)
            scheduleRestart(ranFor: 0)
            return
        }
        openOutputs += 1
        child = c
        lock.writePID(c.pid)
        state = .running(pid: c.pid, since: c.startedAt)
    }

    private func drain(_ c: Child) {
        guard !c.outputClosed else { return }
        let (data, eof) = c.inbox.take()
        for line in c.buffer.append(data) {
            if let ev = AutoEvent.parse(line) { onEvent?(ev, line) }
        }
        if eof { closeOutput(c) }
    }

    private func closeOutput(_ c: Child) {
        guard !c.outputClosed else { return }
        c.outputClosed = true
        c.output.readabilityHandler = nil
        openOutputs -= 1
    }

    private func exited(_ c: Child, status: Int32, reason: Process.TerminationReason) {
        guard !c.exited else { return }
        c.exited = true
        c.killTask?.cancel()
        if !c.outputClosed {
            let grace = eofGrace
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(grace))
                self?.drain(c)
                self?.closeOutput(c)
            }
        }
        guard child === c else { return }
        child = nil
        lock.clearPID()
        guard wanted else {
            lock.release()
            return
        }
        // A pending debounced restart spawns when it fires.
        guard restartTask == nil else { return }
        // Intentional stop (restart, or off then on): spawn now. A core
        // without a SIGUSR1 handler dies of the wake signal: respawning at
        // once is the wake.
        if c.stopping || (reason == .uncaughtSignal && status == SIGUSR1) {
            spawn()
            return
        }
        scheduleRestart(ranFor: Date().timeIntervalSince(c.startedAt))
    }

    private func scheduleRestart(ranFor: TimeInterval) {
        let delay = backoff.nextDelay(ranFor: ranFor)
        state = .restarting(at: Date().addingTimeInterval(delay))
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.restartTask = nil
            self.spawn()
        }
    }
}

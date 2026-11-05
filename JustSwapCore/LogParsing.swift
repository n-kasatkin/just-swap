import Foundation

/// Reads `~/.claude-swap-backup/claude-swap.log`: switch history, per-account
/// usage samples (for sparklines) and the raw tail.
public enum SwapLog {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-swap-backup", isDirectory: true)
    }
    public static var logURL: URL { directory.appendingPathComponent("claude-swap.log") }
    public static var rotatedURL: URL { directory.appendingPathComponent("claude-swap.log.1") }

    /// The last `maxBytes` of a file, starting at a line boundary.
    public static func tail(_ url: URL, maxBytes: Int = 256 * 1024) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? h.seek(toOffset: start)
        let data = (try? h.readToEnd()) ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
        return text
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// "2026-11-05 10:59:26,862 - INFO - …" → the local time of the line.
    public static func lineDate(_ line: Substring) -> Date? {
        guard line.count >= 19 else { return nil }
        return stampFormatter.date(from: String(line.prefix(19)))
    }

    public struct Line: Identifiable, Sendable, Equatable {
        public var id: Int
        public var date: Date?
        public var level: String
        public var message: String
    }

    public static func lines(_ text: String) -> [Line] {
        text.split(separator: "\n", omittingEmptySubsequences: true).enumerated().map { i, raw in
            let parts = raw.components(separatedBy: " - ")
            if parts.count >= 3, let d = lineDate(raw) {
                return Line(id: i, date: d, level: parts[1], message: parts[2...].joined(separator: " - "))
            }
            return Line(id: i, date: nil, level: "", message: String(raw))
        }
    }

    // MARK: switch history

    private static let switchRegex = try! NSRegularExpression(pattern: #"Switched from account (\d+) to (\d+)"#)

    public static func switches(_ text: String) -> [SwitchRecord] {
        var out: [SwitchRecord] = []
        for raw in text.split(separator: "\n") {
            let s = String(raw)
            guard let m = switchRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let date = lineDate(raw),
                  let from = Int(s[Range(m.range(at: 1), in: s)!]),
                  let to = Int(s[Range(m.range(at: 2), in: s)!]) else { continue }
            out.append(SwitchRecord(date: date, from: from, to: to, trigger: nil))
        }
        return out
    }

    // MARK: usage samples

    public struct UsageSample: Sendable, Equatable {
        public var date: Date
        public var fiveHour: Double?
        public var sevenDay: Double?
    }

    /// email → samples in time order, from the core's de-duplicated
    /// `usage <email>: 5h N% … · 7d M% …` log lines.
    public static func usageSamples(_ text: String) -> [String: [UsageSample]] {
        var out: [String: [UsageSample]] = [:]
        for raw in text.split(separator: "\n") where raw.contains(" - usage ") {
            guard let date = lineDate(raw) else { continue }
            let s = String(raw)
            guard let marker = s.range(of: " - usage ") else { continue }
            let rest = s[marker.upperBound...]
            guard let colon = rest.range(of: ": ") else { continue }
            let email = String(rest[..<colon.lowerBound])
            let body = rest[colon.upperBound...]
            let five = pct(after: "5h ", in: body)
            let seven = pct(after: "7d ", in: body)
            guard five != nil || seven != nil else { continue }
            out[email, default: []].append(UsageSample(date: date, fiveHour: five, sevenDay: seven))
        }
        return out
    }

    private static func pct(after label: String, in body: Substring) -> Double? {
        guard let r = body.range(of: label) else { return nil }
        let digits = body[r.upperBound...].prefix { $0.isNumber || $0 == "." }
        guard body[r.upperBound...].dropFirst(digits.count).first == "%" else { return nil }
        return Double(digits)
    }
}

public struct SwitchRecord: Codable, Sendable, Equatable, Identifiable {
    public var date: Date
    public var from: Int?
    public var to: Int?
    /// The autoswitch trigger ("proactive", "at-limit" …); nil for a manual
    /// or unattributed switch.
    public var trigger: String?

    public var id: String { "\(date.timeIntervalSince1970)-\(from ?? -1)-\(to ?? -1)" }

    public init(date: Date, from: Int?, to: Int?, trigger: String?) {
        self.date = date
        self.from = from
        self.to = to
        self.trigger = trigger
    }

    /// Log lines plus stored autoswitch events, newest first. An event that
    /// matches a log line (same pair within 30 s) lends it its trigger.
    public static func merge(log: [SwitchRecord], events: [SwitchRecord], limit: Int = 100) -> [SwitchRecord] {
        var merged = log
        for ev in events {
            if let i = merged.firstIndex(where: {
                $0.from == ev.from && $0.to == ev.to && abs($0.date.timeIntervalSince(ev.date)) < 30
            }) {
                merged[i].trigger = merged[i].trigger ?? ev.trigger
            } else {
                merged.append(ev)
            }
        }
        return Array(merged.sorted { $0.date > $1.date }.prefix(limit))
    }
}

/// Switch events from the supervised auto loop, kept in Application Support
/// as one JSON line each (the core logs no trigger with its switch line).
public struct SwitchEventStore: Sendable {
    public let url: URL

    public init(url: URL = SupervisorLock.defaultDirectory.appendingPathComponent("switches.jsonl")) {
        self.url = url
    }

    public func append(rawLine: String) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data((rawLine.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    public func load() -> [SwitchRecord] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard case .switched(let e)? = AutoEvent.parse(line), e.dryRun != true,
                  let date = e.ts.flatMap(ISODate.parse) else { return nil }
            return SwitchRecord(date: date, from: e.from?.number, to: e.to?.number, trigger: e.trigger)
        }
    }
}

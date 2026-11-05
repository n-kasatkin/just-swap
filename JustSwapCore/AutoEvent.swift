import Foundation

public struct AccountRef: Codable, Sendable, Equatable {
    public var number: Int?
    public var email: String?
}

/// One line of `cswap auto --json`. Unknown event kinds decode to `.unknown`
/// so a newer core never breaks the stream.
public enum AutoEvent: Sendable, Equatable {
    public struct Poll: Codable, Sendable, Equatable {
        public var ts: String?
        public var active: AccountRef?
        public var headroomPct: [String: Double?]?
        public var threshold: Double?
        public var weeklyThreshold: Double?
        public var fetchErrors: [String: String]?
        public var windowsPct: [String: [String: Double]]?

        /// The switch line the engine applied to the active slot's `window`:
        /// the poll's own lines, with `configuredWeekly` (`autoswitch.weeklyThreshold`)
        /// before the 5h line for 7d, and `fallback` when the poll carries no 5h line.
        public func line(for window: String, configuredWeekly: Double?, fallback: Double) -> Double {
            let fiveHour = threshold ?? fallback
            guard window == "7d" else { return fiveHour }
            return weeklyThreshold ?? configuredWeekly ?? fiveHour
        }
    }

    public struct Switch: Codable, Sendable, Equatable {
        public var ts: String?
        public var trigger: String?
        public var from: AccountRef?
        public var to: AccountRef?
        public var warnings: [String]?
        public var dryRun: Bool?
    }

    public struct NoSwitch: Codable, Sendable, Equatable {
        public var ts: String?
        public var reason: String?
        public var detail: String?
    }

    public struct AccountChange: Codable, Sendable, Equatable {
        public var ts: String?
        public var number: String?
        public var email: String?
        public var reason: String?
    }

    public struct AllExhausted: Codable, Sendable, Equatable {
        public var ts: String?
        public var earliestResetAt: String?
    }

    public struct Sleep: Codable, Sendable, Equatable {
        public var ts: String?
        public var seconds: Double?
        public var until: String?
    }

    public struct Message: Codable, Sendable, Equatable {
        public var ts: String?
        public var message: String?
        public var transient: Bool?
    }

    case poll(Poll)
    case switched(Switch)
    case noSwitch(NoSwitch)
    case quarantined(AccountChange)
    case unquarantined(AccountChange)
    case allExhausted(AllExhausted)
    case sleep(Sleep)
    case error(Message)
    case configWarning(Message)
    case unknown(kind: String)

    private struct Head: Decodable { var event: String? }

    /// Parses one JSONL line; nil for blank or non-JSON lines.
    public static func parse(_ line: some StringProtocol) -> AutoEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        let dec = JSONDecoder()
        guard let head = try? dec.decode(Head.self, from: data), let kind = head.event else { return nil }
        func d<T: Decodable>(_ t: T.Type) -> T? { try? dec.decode(t, from: data) }
        switch kind {
        case "poll": return d(Poll.self).map(AutoEvent.poll)
        case "switch": return d(Switch.self).map(AutoEvent.switched)
        case "no-switch": return d(NoSwitch.self).map(AutoEvent.noSwitch)
        case "account-quarantined": return d(AccountChange.self).map(AutoEvent.quarantined)
        case "account-unquarantined": return d(AccountChange.self).map(AutoEvent.unquarantined)
        case "all-exhausted": return d(AllExhausted.self).map(AutoEvent.allExhausted)
        case "sleep": return d(Sleep.self).map(AutoEvent.sleep)
        case "error": return d(Message.self).map(AutoEvent.error)
        case "config-warning": return d(Message.self).map(AutoEvent.configWarning)
        default: return .unknown(kind: kind)
        }
    }

    public var timestamp: Date? {
        let ts: String?
        switch self {
        case .poll(let e): ts = e.ts
        case .switched(let e): ts = e.ts
        case .noSwitch(let e): ts = e.ts
        case .quarantined(let e), .unquarantined(let e): ts = e.ts
        case .allExhausted(let e): ts = e.ts
        case .sleep(let e): ts = e.ts
        case .error(let e), .configWarning(let e): ts = e.ts
        case .unknown: ts = nil
        }
        return ts.flatMap(ISODate.parse)
    }

    /// A user-facing notification for the events the old menu bar announced
    /// (`menubar.py` `_drain_engine_events`); nil for everything else.
    public var notification: (title: String, body: String)? {
        switch self {
        case .switched(let e) where e.dryRun != true:
            let from = e.from?.number.map { "Account-\($0)" } ?? "(none)"
            let to = e.to.map { "Account-\($0.number.map(String.init) ?? "?") (\($0.email ?? "?"))" } ?? "?"
            return ("Auto-switched account", "\(from) → \(to) (\(e.trigger ?? "auto"))")
        case .quarantined(let e):
            return ("Account quarantined",
                    "Account-\(e.number ?? "?") (\(e.email ?? "?")): \(e.reason ?? "credentials rejected")")
        case .allExhausted(let e):
            let when = e.earliestResetAt.flatMap(ISODate.parse).map { Format.clock($0) }
            return ("All accounts exhausted",
                    when.map { "Earliest reset at \($0)" } ?? "No reset time known")
        case .configWarning(let e):
            return ("Configuration warning", e.message ?? "")
        default:
            return nil
        }
    }
}

public enum Format {
    public static func clock(_ date: Date, seconds: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        let sameDay = Calendar.current.isDate(date, inSameDayAs: Date())
        f.dateFormat = (sameDay ? "" : "MMM d ") + (seconds ? "HH:mm:ss" : "HH:mm")
        return f.string(from: date)
    }

    /// "2h 44m", "5d 18h", "12m", "now".
    public static func countdown(to date: Date, from now: Date = Date()) -> String {
        let s = Int(date.timeIntervalSince(now))
        if s <= 0 { return "now" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return m > 0 ? "\(m)m" : "<1m"
    }

    /// "34m", "2h21m", "5d17h": a reset countdown in a row's tight column; nil once passed.
    public static func compactCountdown(to date: Date, from now: Date = Date()) -> String? {
        let s = Int(date.timeIntervalSince(now))
        if s <= 0 { return nil }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d\(h)h" }
        if h > 0 { return "\(h)h\(m)m" }
        return m > 0 ? "\(m)m" : "<1m"
    }

    /// "18s ago", "5m ago", "3h ago".
    public static func ago(_ date: Date, from now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return "\(max(s, 0))s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }

    public static func percent(_ v: Double) -> String { "\(Int(v.rounded()))%" }
}

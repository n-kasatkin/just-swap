import Foundation

/// What a collapsed slot row shows: the two window readings, a status glyph
/// when the slot is not fine, the 7d pace marker and how fresh the reading is.
public struct SlotSummary: Equatable, Sendable {
    public var health: SlotHealth
    public var fiveHour: Double?
    public var sevenDay: Double?
    /// The windows drawn as spent (100 %) for a limited slot.
    public var fiveHourSpent: Bool
    public var sevenDaySpent: Bool
    /// The core's noise-gated pace signal for the 7d window.
    public var aheadOfPace: Bool
    public var projectedExhaustion: Date?
    public var checkedAt: Date?
    /// Each window's reading as a collapsed row draws it.
    public var fiveHourWindow: WindowCell
    public var sevenDayWindow: WindowCell

    /// One window of a collapsed row: the reading, whether it runs ahead of
    /// pace, and when it resets.
    public struct WindowCell: Equatable, Sendable {
        public var pct: Double?
        public var aheadOfPace: Bool
        public var resetsAt: Date?
        public var expectedPct: Double?
        public var projectedExhaustion: Date?

        public init(_ w: UsageWindow?, pct: Double?) {
            self.pct = pct
            aheadOfPace = w?.aheadOfPace == true
            resetsAt = w?.resetDate
            expectedPct = w?.expectedPct
            projectedExhaustion = w?.projectedExhaustionAt.flatMap(ISODate.parse)
        }

        public func countdown(now: Date = Date()) -> String? {
            resetsAt.flatMap { Format.compactCountdown(to: $0, from: now) }
        }

        /// The window as fixed monospaced cells, so every row lines up:
        /// label (2), a space, arrow and percentage right-aligned in 5 with
        /// the arrow tight to the digits, a space, countdown left-aligned in 5.
        public func cells(label: String, now: Date = Date()) -> Cells {
            let arrow = aheadOfPace ? "↗" : ""
            let percent = pct.map(Format.percent) ?? "–"
            return Cells(label: Self.pad(label, Cells.labelWidth),
                         pad: String(repeating: " ", count: max(0, Cells.groupWidth - arrow.count - percent.count)),
                         arrow: arrow, percent: percent,
                         countdown: Self.pad(countdown(now: now) ?? "", Cells.countdownWidth))
        }

        private static func pad(_ s: String, _ width: Int) -> String {
            s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
        }

        /// The runs of one window's cells, kept apart so each can take its colour.
        public struct Cells: Equatable, Sendable {
            public static let labelWidth = 2
            public static let groupWidth = 5
            public static let countdownWidth = 5
            /// `5h ↗42% 2h31m` in character cells.
            public static let width = labelWidth + 1 + groupWidth + 1 + countdownWidth

            public var label: String
            public var pad: String
            public var arrow: String
            public var percent: String
            public var countdown: String

            public var text: String { label + " " + pad + arrow + percent + " " + countdown }
        }

        /// Tooltip of the pace arrow: expected against used, and the projected run-out.
        public func paceHelp(window: String, clock: (Date) -> String) -> String {
            var s = "\(window) ahead of pace"
            if let e = expectedPct, let p = pct { s += ": \(Format.percent(e)) expected by now, \(Format.percent(p)) used" }
            if let at = projectedExhaustion { s += "; runs out \(clock(at))" }
            return s
        }
    }

    public init(row: AccountRow) {
        health = SlotHealth(row: row)
        let usage = row.displayUsage
        let spent = Self.spentWindows(row: row, health: health)
        fiveHourSpent = spent.five
        sevenDaySpent = spent.seven
        fiveHour = spent.five ? 100 : usage?.fiveHour?.pct
        sevenDay = spent.seven ? 100 : usage?.sevenDay?.pct
        aheadOfPace = usage?.sevenDay?.aheadOfPace == true
        projectedExhaustion = usage?.sevenDay?.projectedExhaustionAt.flatMap(ISODate.parse)
        checkedAt = row.lastAttemptAt
        fiveHourWindow = WindowCell(usage?.fiveHour, pct: fiveHour)
        sevenDayWindow = WindowCell(usage?.sevenDay, pct: sevenDay)
    }

    /// Which windows to draw as spent for a limited slot: any at 100 %,
    /// else the one whose reset matches the refusal, else the 5h one.
    public static func spentWindows(row: AccountRow, health: SlotHealth) -> (five: Bool, seven: Bool) {
        guard case .limited = health, let u = row.usage else { return (false, false) }
        let five = (u.fiveHour?.pct ?? 0) >= 100, seven = (u.sevenDay?.pct ?? 0) >= 100
        if five || seven { return (five, seven) }
        if let r = u.rejected?.resetsAt {
            if u.sevenDay?.resetsAt == r { return (false, true) }
            if u.fiveHour?.resetsAt == r { return (true, false) }
        }
        return (true, false)
    }

    /// An SF Symbol for a slot that needs a look; nil when it is fine or heals on its own.
    public var glyph: String? {
        switch health {
        case .limited: return "hourglass"
        case .quarantined: return "nosign"
        case .reloginRequired: return "person.crop.circle.badge.exclamationmark"
        case .fetchError, .foreignCredential: return "exclamationmark.triangle"
        case .keychainUnavailable: return "lock"
        case .healthy, .tokenExpired, .noCredentials, .apiKey, .unknown: return nil
        }
    }

    /// "now", "4m", "3h", "2d": the age of the last check.
    public static func freshness(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    /// Tooltip of the ahead-of-pace marker.
    public func aheadHelp(clock: (Date) -> String) -> String {
        "Spending faster than the 7-day pace"
            + (projectedExhaustion.map { "; projected to run out at \(clock($0))" } ?? "")
    }

    /// The expanded row's pace line for the 7d window: expected share by now
    /// against the actual one, and where the current rate leads.
    public static func paceLine(_ w: UsageWindow?, clock: (Date) -> String) -> String? {
        guard let w, let expected = w.expectedPct, let pct = w.pct else { return nil }
        var s = "Pace \(Format.percent(expected)) expected by now, \(Format.percent(pct)) used"
        if w.willLastToReset == true {
            s += " · lasts to the reset"
        } else if let at = w.projectedExhaustionAt.flatMap(ISODate.parse) {
            s += " · runs out \(clock(at))"
        }
        return s
    }

    /// The spoken label of a collapsed row: name, readings, status, pace.
    public func accessibilityLabel(name: String, active: Bool, enabled: Bool, status: String?) -> String {
        var parts = [name]
        if active { parts.append("active") }
        if !enabled { parts.append("held out") }
        parts.append("5h " + (fiveHour.map(Format.percent) ?? "no reading"))
        parts.append("7d " + (sevenDay.map(Format.percent) ?? "no reading"))
        if glyph != nil, let status { parts.append(status) }
        if aheadOfPace { parts.append("ahead of the 7-day pace") }
        return parts.joined(separator: ", ")
    }
}

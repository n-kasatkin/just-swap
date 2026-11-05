import Foundation

/// Plain-English descriptions of every `autoswitch.strategy` choice, written
/// from the core's engine (`autoswitch.py`: `_tick_inner`, `_rank_candidates`,
/// `_rank_priority_candidates`; `lines.py`: `window_line`). Disabled and
/// quarantined accounts are never candidates; API-key accounts only with
/// `includeApiKeyAccounts`, as a last resort (see `interplay`).
public enum StrategyInfo {
    public struct Entry: Sendable, Equatable {
        public var name: String
        public var title: String
        /// When the engine leaves the active account.
        public var leaves: String
        /// Which account it lands on.
        public var picks: String
    }

    public static let entries: [Entry] = [
        Entry(name: "best", title: "Most room",
              leaves: "Leaves the active account when one of its windows reaches its switch line or hits its limit, or when its usage stays unreadable for several polls in a row.",
              picks: "At the line it moves to the account with the most room under its own lines, and only when that beats the active one by the hysteresis margin, so two accounts near the line do not trade places. At the limit or after unreadable polls it takes the account with the most room, even one over its own line."),
        Entry(name: "weekly-first", title: "Weekly reset first",
              leaves: "Leaves like Most room: at the switch line, at the limit, or after unreadable polls.",
              picks: "At the line it picks, among the accounts under their lines that beat the active one by the hysteresis margin, the one whose 7-day window resets soonest, since its unused weekly quota is lost first. At the limit or after unreadable polls it picks like Most room."),
        Entry(name: "consume-first", title: "Spend expiring quota",
              leaves: "Also leaves before the line, when an account under its lines has a 7-day window that resets sooner than the active one's.",
              picks: "Picks the account whose 7-day window resets soonest; room breaks ties. Before and at the line it lands only on accounts under their lines; at the limit or after unreadable polls any account with room left qualifies, even one over its line."),
        Entry(name: "priority-consume-first", title: "Priority tiers",
              leaves: "Also leaves before the line, whenever an account under its lines sits in a higher tier, or in the same tier with a sooner 7-day reset.",
              picks: "Picks the highest priority tier first, then the soonest 7-day reset within the tier. It lands only on an account under all its lines, even at the limit or after unreadable polls; when there is none, it stays and waits."),
    ]

    /// How priority tiers, per-account thresholds and API-key accounts act on every strategy.
    public static let interplay = "Priority tiers count only under Priority tiers. A per-account threshold replaces autoswitch.threshold for that account: it is the line of all its windows, or only of the 5h window when autoswitch.weeklyThreshold is set, since the 7-day windows then keep the weekly line. When no account is under its lines, Most room, Weekly reset first and Spend expiring quota take the account with the most room left; Priority tiers waits. API-key accounts are picked only with includeApiKeyAccounts on, and only when the engine must leave and no other account qualifies."

    public static func entry(_ name: String) -> Entry? { entries.first { $0.name == name } }

    /// One paragraph for the picker's caption.
    public static func summary(_ name: String) -> String? {
        entry(name).map { "\($0.leaves) \($0.picks)" }
    }

    /// Schema choices without a description: empty when the app covers the core.
    public static func undescribed(_ choices: [String]) -> [String] {
        choices.filter { entry($0) == nil }
    }
}

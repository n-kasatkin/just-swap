import Foundation

/// Token health of one slot, derived from a list row.
public enum SlotHealth: Equatable, Sendable {
    case healthy
    /// The probe was refused or a window is spent; `until` is when it lifts.
    case limited(until: Date?)
    case quarantined(reason: String?)
    case reloginRequired
    case tokenExpired
    case keychainUnavailable
    case foreignCredential
    case noCredentials
    case apiKey
    case fetchError(String)
    case unknown

    public enum Tone: Sendable { case good, warn, bad, neutral, info }

    public init(row: AccountRow) {
        if let q = row.quarantine {
            self = .quarantined(reason: q.reason)
            return
        }
        switch row.usageStatus {
        case "ok":
            if let usage = row.usage, let limit = SlotHealth.limit(usage) {
                self = .limited(until: limit.until)
            } else {
                self = .healthy
            }
        case "relogin_required": self = .reloginRequired
        case "token_expired": self = .tokenExpired
        case "keychain_unavailable": self = .keychainUnavailable
        case "foreign_credential": self = .foreignCredential
        case "no_credentials": self = .noCredentials
        case "api_key": self = .apiKey
        default:
            if let err = row.usageError { self = .fetchError(err) } else { self = .unknown }
        }
    }

    public struct Limit: Equatable, Sendable {
        /// End of the limit; nil when the server gave none.
        public var until: Date?
    }

    /// A spent reading: the server's refusal, or a window at 100 %.
    public static func limit(_ usage: Usage) -> Limit? {
        if let rejected = usage.rejected {
            let windowReset = [usage.fiveHour, usage.sevenDay]
                .compactMap { $0 }
                .filter { ($0.pct ?? 0) >= 100 }
                .compactMap(\.resetDate)
                .max()
            return Limit(until: rejected.resetDate ?? windowReset ?? retryDate(rejected))
        }
        let spent = ([usage.fiveHour, usage.sevenDay] + (usage.scoped ?? []).map(Optional.some))
            .compactMap { $0 }
            .filter { ($0.pct ?? 0) >= 100 }
        guard !spent.isEmpty else { return nil }
        return Limit(until: spent.compactMap(\.resetDate).max())
    }

    private static func retryDate(_ r: UsageRejected) -> Date? {
        r.retryAfterS.map { Date().addingTimeInterval($0) }
    }

    public var isLimited: Bool {
        if case .limited = self { return true }
        return false
    }

    public var tone: Tone {
        switch self {
        case .healthy: return .good
        case .apiKey: return .info
        case .limited, .tokenExpired, .keychainUnavailable, .foreignCredential, .fetchError: return .warn
        case .quarantined, .reloginRequired: return .bad
        case .noCredentials, .unknown: return .neutral
        }
    }

    public func label(clock: (Date) -> String) -> String {
        switch self {
        case .healthy: return "Healthy"
        case .limited(let until): return until.map { "Limit until \(clock($0))" } ?? "At limit"
        case .quarantined: return "Quarantined"
        case .reloginRequired: return "Re-login needed"
        case .tokenExpired: return "Token expired"
        case .keychainUnavailable: return "Keychain locked"
        case .foreignCredential: return "Foreign credential"
        case .noCredentials: return "No credentials"
        case .apiKey: return "API key"
        case .fetchError(let e): return "Error · \(e)"
        case .unknown: return "No fresh reading"
        }
    }

    public var detail: String? {
        switch self {
        case .quarantined(let reason):
            return "Held out of rotation\(reason.map { " (\($0))" } ?? ""); log in with it and run cswap add --slot N"
        case .reloginRequired: return "The refresh token is dead; log in again and re-add the slot"
        case .tokenExpired: return "Claude Code refreshes the token on its next request"
        case .keychainUnavailable: return "The login keychain was locked or denied"
        case .foreignCredential: return "The live credential belongs to another account; a switch repairs it"
        case .noCredentials: return "No stored credential for this slot"
        case .apiKey: return "Billed per token; no subscription quota"
        case .limited: return "The server refused the probe; this slot waits for its reset"
        case .fetchError: return "The last usage fetch failed"
        case .healthy, .unknown: return nil
        }
    }
}

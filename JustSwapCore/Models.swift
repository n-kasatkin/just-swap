import Foundation

// Codable mirrors of the claude-swap `--json` payloads (schema v1). Every
// field the core marks additive is optional, and unknown keys are ignored,
// so the app decodes both older and newer cores.

public struct UsageWindow: Codable, Sendable, Equatable {
    /// Null when the usage API sent no utilization for the window.
    public var pct: Double?
    public var resetsAt: String?
    public var countdown: String?
    public var clock: String?
    public var expectedPct: Double?
    public var aheadOfPace: Bool?
    public var projectedExhaustionAt: String?
    public var willLastToReset: Bool?
    public var name: String?

    public init(pct: Double?, resetsAt: String? = nil) {
        self.pct = pct
        self.resetsAt = resetsAt
    }

    public var resetDate: Date? { resetsAt.flatMap(ISODate.parse) }
}

public struct UsageSpend: Codable, Sendable, Equatable {
    public var used: Double?
    public var limit: Double?
    public var pct: Double?
    public var currency: String?
    public var resetsAt: String?
}

public struct UsageRejected: Codable, Sendable, Equatable {
    public var retryAfterS: Double?
    public var resetsAt: String?

    public var resetDate: Date? { resetsAt.flatMap(ISODate.parse) }
}

public struct Usage: Codable, Sendable, Equatable {
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?
    public var spend: UsageSpend?
    public var scoped: [UsageWindow]?
    public var source: String?
    public var rejected: UsageRejected?

    public init(fiveHour: UsageWindow? = nil, sevenDay: UsageWindow? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }
}

public struct Quarantine: Codable, Sendable, Equatable {
    public var reason: String?
    public var at: String?
}

public struct SubscriptionPlan: Codable, Sendable, Equatable {
    public var label: String?
    public var tier: String?
    public var expired: Bool?
    public var fetchedAt: String?
}

/// An account's identity, the key the core's mappings and usage rows use:
/// email plus organization (empty for personal and token accounts).
public struct AccountKey: Hashable, Codable, Sendable {
    public var email: String
    public var organizationUuid: String

    public init(email: String, organizationUuid: String) {
        self.email = email
        self.organizationUuid = organizationUuid
    }
}

public struct AccountRow: Codable, Sendable, Equatable, Identifiable {
    public var number: Int
    public var email: String
    public var organizationName: String?
    public var organizationUuid: String?
    public var isOrganization: Bool?
    public var active: Bool
    public var usageStatus: String
    public var usage: Usage?
    public var alias: String?
    public var disabled: Bool?
    public var threshold: Double?
    /// The `priority-consume-first` tier; absent means 0.
    public var priority: Int?
    public var loginExpiresAt: String?
    public var plan: SubscriptionPlan?
    public var usageFetchedAt: String?
    public var usageAgeSeconds: Double?
    public var lastGoodUsage: Usage?
    public var lastGoodFetchedAt: String?
    public var lastGoodAgeSeconds: Double?
    public var usageError: String?
    public var usageRetryAt: String?
    public var quarantine: Quarantine?
    public var usageLastAttemptAt: String?
    public var usageNextPollAt: String?
    /// Another collector is fetching this slot right now.
    public var usageFetchInFlight: Bool?

    /// Rows are identified by account, not slot: a slot number changes owner on move, swap and remove.
    public var id: AccountKey { key }
    public var key: AccountKey { AccountKey(email: email, organizationUuid: organizationUuid ?? "") }
    public var isEnabled: Bool { !(disabled ?? false) }

    /// Probed by a refresh: every slot, or with `ignoringDisabled` only the
    /// enabled ones and the active one (`--refresh`).
    public func isProbed(ignoringDisabled: Bool) -> Bool {
        !ignoringDisabled || isEnabled || active
    }
    public var displayName: String { (alias?.isEmpty == false ? alias : nil) ?? email }

    /// Usage to draw: the decision-grade value, else the last good reading.
    public var displayUsage: Usage? { usage ?? lastGoodUsage }
    public var isStale: Bool { usage == nil && lastGoodUsage != nil }

    /// When the shown values were measured.
    public var measuredAt: Date? {
        (usageFetchedAt ?? lastGoodFetchedAt).flatMap(ISODate.parse)
    }

    /// The last probe attempt, successful or refused (newer cores report it
    /// separately from the measurement time).
    public var lastAttemptAt: Date? {
        usageLastAttemptAt.flatMap(ISODate.parse) ?? measuredAt
    }

    public var nextAttemptAt: Date? {
        (usageNextPollAt ?? usageRetryAt).flatMap(ISODate.parse)
    }
}

public struct ListPayload: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var activeAccountNumber: Int?
    public var accounts: [AccountRow]
    public var duplicateAccountWarnings: [String]?
    public var lockstepUsageWarnings: [String]?
    public var unclaimedCredentials: [String]?
}

/// A JSON scalar from `config list --json` (`value`, `default`).
public enum JSONScalar: Codable, Sendable, Equatable, CustomStringConvertible {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { self = .null }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        }
    }

    public var description: String {
        switch self {
        case .null: return "unset"
        case .bool(let b): return b ? "on" : "off"
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .string(let s): return s
        }
    }

    /// The form `cswap config set` accepts.
    public var cliValue: String? {
        switch self {
        case .null: return nil
        case .bool(let b): return b ? "true" : "false"
        case .number: return description
        case .string(let s): return s
        }
    }

    public var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

public struct ConfigSetting: Codable, Sendable, Equatable, Identifiable {
    public var key: String
    public var value: JSONScalar
    public var isSet: Bool
    // Schema fields from newer cores; absent on older ones.
    public var kind: String?
    public var `default`: JSONScalar?
    public var min: Double?
    public var max: Double?
    public var choices: [String]?
    public var help: String?

    public var id: String { key }
    public var section: String { String(key.split(separator: ".").first ?? "") }
    public var name: String { String(key.split(separator: ".").dropFirst().joined(separator: ".")) }

    /// The control to render: the schema kind, else inferred from the value.
    public var effectiveKind: String {
        if let kind { return kind }
        switch value {
        case .bool: return "bool"
        case .number: return "float"
        default: return "string"
        }
    }

    /// `usage.headerProbe` must stay on; the app shows it locked and never writes it.
    public var isLocked: Bool { key == "usage.headerProbe" }
}

public struct ConfigPayload: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var path: String?
    public var settings: [ConfigSetting]
}

public struct ErrorEnvelope: Codable, Sendable, Equatable {
    public struct Body: Codable, Sendable, Equatable {
        public var type: String
        public var message: String
    }
    public var schemaVersion: Int?
    public var error: Body
}

public enum ISODate {
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func parse(_ s: String) -> Date? {
        plain.date(from: s) ?? fractional.date(from: s)
    }
}

import Foundation

/// One core run: the arguments after the core command, and what to write to its stdin.
public struct CoreInvocation: Sendable, Equatable {
    public var args: [String]
    public var stdin: String?
    /// Seconds before the run is killed.
    public var timeout: TimeInterval

    public init(_ args: [String], stdin: String? = nil, timeout: TimeInterval = 60) {
        self.args = args
        self.stdin = stdin
        self.timeout = timeout
    }
}

/// Every account change the app makes, as the exact `cswap` command line.
///
/// Mutating commands have no `--json`; they report through the exit status
/// and a stderr line (see `CoreError.from`). The core's own `[y/N]` prompts
/// (remove, purge, add-token onto an occupied slot) are answered on stdin
/// with "y": the app asks first, in its own UI.
public enum AccountCommand: Sendable, Equatable {
    case switchTo(slot: Int)
    case setEnabled(slot: Int, enabled: Bool)
    /// nil or blank removes the alias.
    case setAlias(slot: Int, alias: String?)
    /// nil removes the override (back to `autoswitch.threshold`).
    case setThreshold(slot: Int, percent: Double?)
    /// 0 removes the tier.
    case setPriority(slot: Int, tier: Int)
    /// `cswap add`: the account Claude Code is logged in to now.
    case addCurrent
    /// `cswap add-token -`: a setup-token or API key read from stdin; with a
    /// slot it replaces that slot's credential.
    case addToken(token: String, slot: Int?, email: String?)
    case remove(slot: Int)
    /// Moves an account to a slot number; an occupied slot swaps the two.
    case move(slot: Int, to: Int)
    case swap(Int, Int)
    case export(path: String)
    case importAccounts(path: String, overwrite: Bool)
    case importUsage(path: String)
    case purgeUnclaimed(id: String)
    case map(slot: Int, path: String)
    case unmap(path: String)
    /// Removes every account, credential and setting claude-swap keeps.
    case purgeAll

    /// Why a pasted token cannot be sent, or nil when it can: a token is one
    /// unbroken line, and stdin carries it to the core as exactly that.
    public static func tokenProblem(_ token: String) -> String? {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if t.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) {
            return "A token has no spaces or line breaks: paste it again as one piece"
        }
        return nil
    }

    public var invocation: CoreInvocation {
        switch self {
        case .switchTo(let n):
            return CoreInvocation(["switch", String(n)], timeout: 90)
        case .setEnabled(let n, let on):
            return CoreInvocation([on ? "enable" : "disable", String(n)])
        case .setAlias(let n, let alias):
            let name = alias?.trimmingCharacters(in: .whitespaces) ?? ""
            return CoreInvocation(name.isEmpty ? ["alias", String(n), "--unset"] : ["alias", String(n), name])
        case .setThreshold(let n, let pct):
            return CoreInvocation(["threshold", String(n), pct.map(Self.number) ?? "--unset"])
        case .setPriority(let n, let tier):
            return CoreInvocation(["priority", String(n), tier > 0 ? String(tier) : "--unset"])
        case .addCurrent:
            return CoreInvocation(["add"], timeout: 90)
        case .addToken(let token, let slot, let email):
            var args = ["add-token", "-"]
            if let slot { args += ["--slot", String(slot)] }
            if let email, !email.isEmpty { args += ["--email", email] }
            // The token line, then the answer to "Overwrite slot N?".
            let input = token.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + (slot != nil ? "y\n" : "")
            return CoreInvocation(args, stdin: input, timeout: 90)
        case .remove(let n):
            return CoreInvocation(["remove", String(n)], stdin: "y\n")
        case .move(let n, let to):
            return CoreInvocation(["move", String(n), String(to)])
        case .swap(let a, let b):
            return CoreInvocation(["swap", String(a), String(b)])
        case .export(let path):
            return CoreInvocation(["export", path])
        case .importAccounts(let path, let overwrite):
            return CoreInvocation(["import", path] + (overwrite ? ["--force"] : []), timeout: 90)
        case .importUsage(let path):
            return CoreInvocation(["import-usage", path])
        case .purgeUnclaimed(let id):
            return CoreInvocation(["unclaimed", "--purge", id])
        case .map(let n, let path):
            return CoreInvocation(["map", String(n), path])
        case .unmap(let path):
            return CoreInvocation(["unmap", path])
        case .purgeAll:
            return CoreInvocation(["purge"], stdin: "y\n", timeout: 90)
        }
    }

    /// "85", "99.9": the form `cswap threshold` accepts.
    static func number(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }
}

/// Read-only listings the account pages need beyond `list --json`.
public enum AccountListing {
    public static let mappings = CoreInvocation(["map", "--json"], timeout: 30)
    public static let unclaimed = CoreInvocation(["unclaimed", "--json"], timeout: 30)

    /// Probes one slot now, disabled included (`list --refresh-slot`).
    public static func refreshSlot(_ slot: Int) -> CoreInvocation {
        CoreInvocation(["list", "--json", "--refresh-slot", String(slot)], timeout: 120)
    }
}

public struct MappingsPayload: Codable, Sendable, Equatable {
    public struct Mapping: Codable, Sendable, Equatable, Identifiable {
        public var path: String
        public var email: String
        public var organizationUuid: String?
        /// nil once the mapped account is no longer managed.
        public var slot: Int?
        public var id: String { path }
    }
    public var schemaVersion: Int?
    public var mappings: [Mapping]
}

public struct UnclaimedPayload: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var slot: String?
        public var reason: String?
    }
    public var schemaVersion: Int?
    public var entries: [Entry]
}

/// Drag and drop in the account list: the dragged account lands at the drop
/// row's position and the rows between shift by one. `cswap move` swaps with
/// an occupied slot, so the plan is a chain of neighbour swaps along the
/// slot numbers in list order.
public enum ReorderPlan {
    /// `slots` is the list's slot numbers in display order.
    public static func moves(slots: [Int], from source: Int, to target: Int) -> [AccountCommand] {
        guard let i = slots.firstIndex(of: source), let j = slots.firstIndex(of: target), i != j else { return [] }
        if i < j {
            return (i..<j).map { .move(slot: slots[$0], to: slots[$0 + 1]) }
        }
        return stride(from: i, to: j, by: -1).map { .move(slot: slots[$0], to: slots[$0 - 1]) }
    }

    /// The moves that put back what `done` changed, newest first: every
    /// move is a swap or a move into an empty slot, so the reverse move undoes it.
    public static func undo(_ done: [AccountCommand]) -> [AccountCommand] {
        done.reversed().compactMap {
            if case .move(let a, let b) = $0 { return .move(slot: b, to: a) }
            return nil
        }
    }

    /// The display order after `moves(slots:from:to:)` ran, for checking a plan.
    public static func apply(_ moves: [AccountCommand], to order: [Int: String]) -> [Int: String] {
        var o = order
        for case .move(let a, let b) in moves {
            let x = o[a], y = o[b]
            o[b] = x
            o[a] = y
        }
        return o
    }
}

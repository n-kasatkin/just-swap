import Foundation
import Testing
@testable import JustSwapCore

private final class BundleToken {}

func fixture(_ name: String) throws -> Data {
    let bundle = Bundle(for: BundleToken.self)
    let url = try #require(bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite("list --json decoding")
struct ListDecodingTests {
    @Test func decodesRealNoFetchPayload() throws {
        let p = try JSONDecoder().decode(ListPayload.self, from: fixture("list-no-fetch.json"))
        #expect(p.schemaVersion == 1)
        #expect(p.activeAccountNumber == 1)
        #expect(p.accounts.count == 8)
        let active = try #require(p.accounts.first { $0.active })
        #expect(active.number == 1)
        #expect(active.usage?.fiveHour?.pct == 53)
        #expect(active.usage?.sevenDay?.expectedPct == 17.6)
        #expect(active.usageLastAttemptAt == "2026-11-05T09:37:13Z")
        #expect(active.nextAttemptAt == ISODate.parse("2026-11-05T09:40:07Z"))
        #expect(active.usage?.source == "headers")
        #expect(active.measuredAt != nil)
        let held = p.accounts.filter { !$0.isEnabled }
        #expect(held.map(\.number) == [4, 5, 6, 7, 8])
        let stale = p.accounts[3]
        #expect(stale.usage == nil)
        #expect(stale.isStale)
        #expect(stale.displayUsage?.sevenDay?.pct == 66)
    }

    @Test func ignoresUnknownFieldsAndReadsAdditiveOnes() throws {
        let p = try JSONDecoder().decode(ListPayload.self, from: fixture("list-rich.json"))
        #expect(p.accounts.count == 5)
        #expect(p.accounts[0].plan?.label == "max_20x")
        #expect(p.accounts[0].displayName == "main")
        #expect(p.accounts[1].usage?.rejected?.retryAfterS == 1800)
        #expect(p.accounts[1].usageLastAttemptAt == "2026-11-05T09:30:12Z")
        #expect(p.accounts[1].lastAttemptAt == ISODate.parse("2026-11-05T09:30:12Z"))
        #expect(p.accounts[1].nextAttemptAt == ISODate.parse("2026-11-05T13:00:00Z"))
        #expect(p.accounts[2].usageError == "http-429")
        #expect(p.accounts[2].nextAttemptAt != nil)
        #expect(p.accounts[4].quarantine?.reason == "invalid_grant")
    }

    @Test func nullUtilizationDecodes() throws {
        // oauth.build_usage_result copies the API's utilization, which may be null.
        let raw = String(decoding: try fixture("list-rich.json"), as: UTF8.self)
        let patched = raw.replacingOccurrences(of: "\"pct\": 42.0", with: "\"pct\": null")
        #expect(patched != raw)
        let p = try JSONDecoder().decode(ListPayload.self, from: Data(patched.utf8))
        #expect(p.accounts.count == 5)
        let five = try #require(p.accounts[0].usage?.fiveHour)
        #expect(five.pct == nil)
        #expect(SlotHealth(row: p.accounts[0]) == .healthy)
    }

    @Test func refreshProbesEverySlotUnlessIgnoringDisabled() throws {
        let rows = try JSONDecoder().decode(ListPayload.self, from: fixture("list-no-fetch.json")).accounts
        #expect(rows.filter { $0.isProbed(ignoringDisabled: false) }.map(\.number) == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(rows.filter { $0.isProbed(ignoringDisabled: true) }.map(\.number) == [1, 2, 3])
    }

    @Test func coreTimestampsParse() {
        #expect(ISODate.parse("2026-11-05T12:10:00+00:00") != nil)
        #expect(ISODate.parse("2026-11-05T09:23:15Z") != nil)
        #expect(ISODate.parse("garbage") == nil)
    }
}

@Suite("Slot health")
struct SlotHealthTests {
    let rows: [AccountRow]

    init() throws {
        rows = try JSONDecoder().decode(ListPayload.self, from: fixture("list-rich.json")).accounts
    }

    @Test func mapsEveryState() {
        #expect(SlotHealth(row: rows[0]) == .healthy)
        #expect(SlotHealth(row: rows[1]) == .limited(until: ISODate.parse("2026-11-05T13:00:00+00:00")))
        #expect(SlotHealth(row: rows[2]) == .fetchError("http-429"))
        #expect(SlotHealth(row: rows[3]) == .reloginRequired)
        #expect(SlotHealth(row: rows[4]) == .quarantined(reason: "invalid_grant"))
    }

    @Test func limitedLabelNamesTheEnd() {
        let label = SlotHealth(row: rows[1]).label { _ in "15:00" }
        #expect(label == "Limit until 15:00")
        #expect(SlotHealth(row: rows[1]).tone == .warn)
        #expect(SlotHealth(row: rows[4]).tone == .bad)
    }

    @Test func fullWindowWithoutRefusalIsALimit() {
        let usage = Usage(fiveHour: UsageWindow(pct: 30), sevenDay: UsageWindow(pct: 100, resetsAt: "2026-11-10T04:00:00Z"))
        #expect(SlotHealth.limit(usage) == .init(until: ISODate.parse("2026-11-10T04:00:00Z")))
        #expect(SlotHealth.limit(Usage(fiveHour: UsageWindow(pct: 99))) == nil)
    }
}

@Suite("config list --json decoding")
struct ConfigDecodingTests {
    @Test func legacyRowsFallBackToValueKinds() throws {
        let p = try JSONDecoder().decode(ConfigPayload.self, from: fixture("config-legacy.json"))
        let byKey = Dictionary(uniqueKeysWithValues: p.settings.map { ($0.key, $0) })
        #expect(byKey["autoswitch.threshold"]?.effectiveKind == "float")
        #expect(byKey["autoswitch.weeklyThreshold"]?.value == .null)
        #expect(byKey["autoswitch.weeklyThreshold"]?.effectiveKind == "string")
        #expect(byKey["autoswitch.strategy"]?.effectiveKind == "string")
        #expect(byKey["usage.headerProbe"]?.effectiveKind == "bool")
        #expect(byKey["usage.headerProbe"]?.isLocked == true)
        #expect(byKey["autoswitch.threshold"]?.kind == nil)
    }

    @Test func schemaRowsCarryKindBoundsAndChoices() throws {
        let p = try JSONDecoder().decode(ConfigPayload.self, from: fixture("config-schema.json"))
        let strategy = try #require(p.settings.first { $0.key == "autoswitch.strategy" })
        #expect(strategy.effectiveKind == "choice")
        #expect(strategy.choices?.contains("best") == true)
        let threshold = try #require(p.settings.first { $0.key == "autoswitch.threshold" })
        #expect(threshold.min == 50 && threshold.max == 99.9)
        #expect(threshold.value == .number(90) && threshold.isSet)
        #expect(threshold.default == .number(90))
        let weekly = try #require(p.settings.first { $0.key == "autoswitch.weeklyThreshold" })
        #expect(weekly.default == nil && weekly.value == .null && weekly.effectiveKind == "float")
        #expect(threshold.help?.isEmpty == false)
        #expect(threshold.section == "autoswitch" && threshold.name == "threshold")
        let unhealthy = try #require(p.settings.first { $0.key == "autoswitch.unhealthyTicks" })
        #expect(unhealthy.value.cliValue == "3")
    }
}

@Suite("Error envelope")
struct ErrorEnvelopeTests {
    @Test func envelopeOnStdoutWins() throws {
        let r = ProcessResult(status: 1, stdout: try fixture("error-envelope.json"), stderr: Data("noise\n".utf8))
        #expect(CoreError.from(r) == .failed(status: 1, message: "Account 9 not found", type: "ClaudeSwitchError"))
    }

    @Test func lastStderrLineOtherwise() {
        let stderr = "usage: cswap ...\ncswap: error: unrecognized arguments: --no-fetch\n\n"
        let err = CoreError.from(ProcessResult(status: 2, stdout: Data(), stderr: Data(stderr.utf8)))
        #expect(err == .failed(status: 2, message: "Unrecognized arguments: --no-fetch", type: nil))
        #expect(err.isUnsupportedFlag)
    }

    @Test func emptyOutputNamesTheStatus() {
        let err = CoreError.from(ProcessResult(status: 3, stdout: Data(), stderr: Data()))
        #expect(err.errorDescription == "exit status 3")
        #expect(!err.isUnsupportedFlag)
    }
}

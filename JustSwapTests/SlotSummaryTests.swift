import Foundation
import Testing
@testable import JustSwapCore

@Suite("Slot row summary")
struct SlotSummaryTests {
    let rows: [AccountRow]

    init() throws {
        rows = try JSONDecoder().decode(ListPayload.self, from: fixture("list-rich.json")).accounts
    }

    @Test func statusGlyphOnlyWhenNotFine() {
        let glyphs = rows.map { SlotSummary(row: $0).glyph }
        #expect(glyphs == [nil, "hourglass", "exclamationmark.triangle",
                           "person.crop.circle.badge.exclamationmark", "nosign"])
    }

    @Test func readingsUseSpentWindowsAndLastGoodValues() {
        let limited = SlotSummary(row: rows[1])
        #expect(limited.fiveHourSpent && !limited.sevenDaySpent)
        #expect(limited.fiveHour == 100 && limited.sevenDay == 55)
        let stale = SlotSummary(row: rows[2])
        #expect(stale.fiveHour == 42 && stale.sevenDay == 30)
        let none = SlotSummary(row: rows[3])
        #expect(none.fiveHour == nil && none.sevenDay == nil)
    }

    @Test func aheadOfPaceFollowsTheCoreFlag() {
        #expect(!SlotSummary(row: rows[0]).aheadOfPace)  // willLastToReset false alone is not shown
        #expect(SlotSummary(row: rows[1]).aheadOfPace)
        var row = rows[0]
        row.usage?.sevenDay?.aheadOfPace = true
        let s = SlotSummary(row: row)
        #expect(s.aheadOfPace)
        #expect(s.projectedExhaustion == ISODate.parse("2026-11-08T06:44:28Z"))
        #expect(s.aheadHelp { _ in "Nov 8 08:44" }
            == "Spending faster than the 7-day pace; projected to run out at Nov 8 08:44")
    }

    @Test func paceLine() {
        let clock: (Date) -> String = { _ in "Nov 8 08:44" }
        #expect(SlotSummary.paceLine(rows[0].usage?.sevenDay, clock: clock)
            == "Pace 18% expected by now, 30% used · runs out Nov 8 08:44")
        var w = rows[0].usage?.sevenDay
        w?.willLastToReset = true
        #expect(SlotSummary.paceLine(w, clock: clock) == "Pace 18% expected by now, 30% used · lasts to the reset")
        #expect(SlotSummary.paceLine(rows[0].usage?.fiveHour, clock: clock) == nil)
    }

    @Test func freshness() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(SlotSummary.freshness(nil, now: now) == nil)
        #expect(SlotSummary.freshness(now.addingTimeInterval(-59), now: now) == "now")
        #expect(SlotSummary.freshness(now.addingTimeInterval(5), now: now) == "now")
        #expect(SlotSummary.freshness(now.addingTimeInterval(-60), now: now) == "1m")
        #expect(SlotSummary.freshness(now.addingTimeInterval(-3599), now: now) == "59m")
        #expect(SlotSummary.freshness(now.addingTimeInterval(-3 * 3600), now: now) == "3h")
        #expect(SlotSummary.freshness(now.addingTimeInterval(-2 * 86400), now: now) == "2d")
        #expect(SlotSummary(row: rows[1]).checkedAt == ISODate.parse("2026-11-05T09:30:12Z"))
    }

    @Test func accessibilityLabel() {
        #expect(SlotSummary(row: rows[0]).accessibilityLabel(name: "main", active: true, enabled: true, status: "Healthy")
            == "main, active, 5h 42%, 7d 30%")
        #expect(SlotSummary(row: rows[1]).accessibilityLabel(name: "a2", active: false, enabled: true, status: "Limit until 15:00")
            == "a2, 5h 100%, 7d 55%, Limit until 15:00, ahead of the 7-day pace")
        #expect(SlotSummary(row: rows[3]).accessibilityLabel(name: "a4", active: false, enabled: false, status: "Re-login needed")
            == "a4, held out, 5h no reading, 7d no reading, Re-login needed")
    }
}

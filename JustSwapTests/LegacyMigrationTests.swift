import Foundation
import Testing
@testable import JustSwapCore

@Suite("Legacy migration")
struct LegacyMigrationTests {
    let suite = "test.justswap.migration.\(UUID().uuidString)"
    let legacySuite = "test.justswap.legacy.\(UUID().uuidString)"
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    @Test func copiesKnownKeysAndHistoryOnce() throws {
        let defaults = UserDefaults(suiteName: suite)!, legacy = UserDefaults(suiteName: legacySuite)!
        defer { defaults.removePersistentDomain(forName: suite); legacy.removePersistentDomain(forName: legacySuite)
                try? FileManager.default.removeItem(at: root) }
        legacy.set(false, forKey: "autoSwitchEnabled")
        legacy.set(true, forKey: "menuBarShowFiveHour")
        legacy.set(true, forKey: "loginItemDefaultApplied")
        defaults.set(true, forKey: "menuBarShowFiveHour")
        let oldDir = root.appendingPathComponent("ClaudeSwapBar"), newDir = root.appendingPathComponent("just swap")
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try Data("{\"event\":\"switched\"}\n".utf8).write(to: oldDir.appendingPathComponent("switches.jsonl"))

        LegacyMigration.run(defaults: defaults, legacy: legacy, legacyDirectory: oldDir, directory: newDir)

        #expect(defaults.object(forKey: "autoSwitchEnabled") as? Bool == false)
        #expect(defaults.object(forKey: "loginItemDefaultApplied") == nil)
        #expect(FileManager.default.fileExists(atPath: newDir.appendingPathComponent("switches.jsonl").path))

        legacy.set(true, forKey: "autoSwitchEnabled")
        LegacyMigration.run(defaults: defaults, legacy: legacy, legacyDirectory: oldDir, directory: newDir)
        #expect(defaults.object(forKey: "autoSwitchEnabled") as? Bool == false)
    }
}

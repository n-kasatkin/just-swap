import Foundation

/// One-time move of the settings and switch history kept by the app's
/// pre-release builds, which used the defaults domain
/// `dev.<user name>.ClaudeSwapBar` and the folder
/// `Application Support/ClaudeSwapBar`. Values already set under the new
/// domain win; a marker key keeps it from running twice.
public enum LegacyMigration {
    public static let legacyDomain = "dev.\(NSUserName()).ClaudeSwapBar"
    public static let legacyFolderName = "ClaudeSwapBar"
    static let doneKey = "legacyMigrationDone"
    /// The app's own preference keys; window frames and the login-item
    /// marker stay behind, so the app registers its own login item.
    static let keys = [
        "autoSwitchEnabled", "refreshIgnoresDisabled", "CSWAP_PATH",
        "menuBarShowLogo", "menuBarShowAccount", "menuBarShowOrganization",
        "menuBarShowFiveHour", "menuBarShowSevenDay", "menuBarIconHidden",
        "titleMode", "showAccountName",
    ]

    public static func run(defaults: UserDefaults = .standard,
                           legacy: UserDefaults? = UserDefaults(suiteName: legacyDomain),
                           legacyDirectory: URL = SupervisorLock.defaultDirectory
                               .deletingLastPathComponent().appendingPathComponent(legacyFolderName, isDirectory: true),
                           directory: URL = SupervisorLock.defaultDirectory) {
        guard !defaults.bool(forKey: doneKey) else { return }
        if let legacy {
            for key in keys where defaults.object(forKey: key) == nil {
                if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
            }
        }
        let fm = FileManager.default
        let old = legacyDirectory.appendingPathComponent("switches.jsonl")
        let new = directory.appendingPathComponent("switches.jsonl")
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try? fm.copyItem(at: old, to: new)
        }
        defaults.set(true, forKey: doneKey)
    }
}

import Foundation

/// UserDefaults keys for the status item, one per switch on the settings page.
public enum MenuBarPrefs {
    public static let logo = "menuBarShowLogo"
    public static let account = "menuBarShowAccount"
    public static let organization = "menuBarShowOrganization"
    public static let fiveHour = "menuBarShowFiveHour"
    public static let sevenDay = "menuBarShowSevenDay"
    /// Removes the status item; reopening the app shows the popover in a window.
    public static let hidden = "menuBarIconHidden"
    /// A `TitleSeparator` preset or its custom tag, and the custom string.
    public static let separator = "menuBarSeparator"
    public static let customSeparator = "menuBarSeparatorCustom"

    public static var defaults: [String: Any] {
        let d = MenuBarItems()
        return [
            logo: d.logo, account: d.account, organization: d.organization,
            fiveHour: d.fiveHour, sevenDay: d.sevenDay, hidden: false,
            separator: TitleSeparator.standard, customSeparator: "",
        ]
    }

    /// Registration is process-wide, whichever UserDefaults instance it goes through.
    public static func register(_ ud: UserDefaults = .standard) {
        ud.register(defaults: defaults)
        migrate(ud)
    }

    /// One-time move from `titleMode` + `showAccountName`: only values the
    /// user actually stored count, then the old keys go.
    private static func migrate(_ ud: UserDefaults) {
        let mode = ud.string(forKey: "titleMode")
        let account = ud.object(forKey: "showAccountName") as? Bool
        guard mode != nil || account != nil else { return }
        let items = MenuBarItems.migrated(titleMode: mode, showAccountName: account)
        ud.set(items.logo, forKey: logo)
        ud.set(items.account, forKey: Self.account)
        ud.set(items.organization, forKey: organization)
        ud.set(items.fiveHour, forKey: fiveHour)
        ud.set(items.sevenDay, forKey: sevenDay)
        ud.removeObject(forKey: "titleMode")
        ud.removeObject(forKey: "showAccountName")
    }
}

/// App switches on the settings page that are not about the status item.
public enum AppPrefs {
    /// Refresh skips disabled slots.
    public static let ignoreDisabled = "refreshIgnoresDisabled"
    /// Shows the Log tab.
    public static let showLogTab = "showLogTab"
    public static let autoSwitchEnabled = "autoSwitchEnabled"

    public static let defaults: [String: Bool] = [autoSwitchEnabled: true, ignoreDisabled: false, showLogTab: false]

    public static func register(_ ud: UserDefaults = .standard) {
        ud.register(defaults: defaults)
    }
}

/// The popover's tabs. Log is hidden unless "Show log tab" is on.
public enum PopoverTab: String, CaseIterable, Identifiable, Sendable {
    case accounts, autoswitch, history, log
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .accounts: return "Accounts"
        case .autoswitch: return "Autoswitch"
        case .history: return "History"
        case .log: return "Log"
        }
    }

    public var icon: String {
        switch self {
        case .accounts: return "person.2"
        case .autoswitch: return "arrow.triangle.2.circlepath"
        case .history: return "clock.arrow.circlepath"
        case .log: return "text.alignleft"
        }
    }

    public static func visible(showLog: Bool) -> [PopoverTab] {
        showLog ? allCases : allCases.filter { $0 != .log }
    }

    /// `--tab` values; the old names open the tabs that took their place.
    public init?(argument: String) {
        switch argument.lowercased() {
        case "slots", "tokens": self = .accounts
        default: self.init(rawValue: argument.lowercased())
        }
    }
}

/// Where each `cswap config` key is edited: `autoswitch.*` on the Autoswitch
/// tab, everything else on the settings page, sections in schema order.
public enum SettingsLayout {
    public static let autoswitchSection = "autoswitch"

    public static func autoswitch(_ settings: [ConfigSetting]) -> [ConfigSetting] {
        settings.filter { $0.section == autoswitchSection }
    }

    public static func generalSections(_ settings: [ConfigSetting]) -> [(section: String, settings: [ConfigSetting])] {
        var order: [String] = []
        for s in settings where s.section != autoswitchSection && !order.contains(s.section) { order.append(s.section) }
        return order.map { sec in (sec, settings.filter { $0.section == sec }) }
    }
}

import Foundation

/// What the menu bar status item shows; each part is independent.
public struct MenuBarItems: Equatable, Sendable {
    public var logo: Bool
    public var account: Bool
    public var organization: Bool
    public var fiveHour: Bool
    public var sevenDay: Bool

    public init(logo: Bool = true, account: Bool = false, organization: Bool = false,
                fiveHour: Bool = false, sevenDay: Bool = false) {
        self.logo = logo
        self.account = account
        self.organization = organization
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    /// The items the pre-checkbox settings stood for: `titleMode` (none, 5h,
    /// 7d, both) and `showAccountName`, with their old defaults for a missing value.
    public static func migrated(titleMode: String?, showAccountName: Bool?) -> MenuBarItems {
        let mode = titleMode ?? "5h"
        return MenuBarItems(account: showAccountName ?? true,
                            fiveHour: mode == "5h" || mode == "both",
                            sevenDay: mode == "7d" || mode == "both")
    }
}

/// What goes between the text parts of the status item: a preset or a short custom string.
public enum TitleSeparator {
    public static let standard = " · "
    public static let presets = [" · ", " | ", " / ", " — ", " "]
    /// The stored choice that selects the custom string.
    public static let customTag = "custom"
    public static let customMaxLength = 3

    /// The separator for a stored choice: a preset as is, the custom string cut
    /// to `customMaxLength`, and the standard one for an empty custom string or
    /// an unknown choice.
    public static func resolve(choice: String?, custom: String?) -> String {
        if choice == customTag {
            let c = String((custom ?? "").prefix(customMaxLength))
            return c.isEmpty ? standard : c
        }
        if let choice, presets.contains(choice) { return choice }
        return standard
    }
}

public struct StatusTitle: Equatable, Sendable {
    public var logo: Bool
    public var text: String?

    /// Composes the status item for the active slot, `separator` between
    /// every visible text part. A window without a reading shows "–"; with no
    /// slot loaded only the logo can show. The logo comes back whenever
    /// nothing else would, so the item is never empty.
    public static func compose(_ items: MenuBarItems, account: String?, organization: String?,
                               usage: Usage?, hasActive: Bool,
                               separator: String = TitleSeparator.standard) -> StatusTitle {
        var parts: [String] = []
        if hasActive {
            if items.account, let a = account, !a.isEmpty { parts.append(a) }
            if items.organization, let o = organization, !o.isEmpty { parts.append(o) }
            if items.fiveHour { parts.append(percent(usage?.fiveHour)) }
            if items.sevenDay { parts.append(percent(usage?.sevenDay)) }
        }
        let text = parts.isEmpty ? nil : parts.joined(separator: separator)
        return StatusTitle(logo: items.logo || text == nil, text: text)
    }

    private static func percent(_ w: UsageWindow?) -> String {
        w?.pct.map(Format.percent) ?? "–"
    }
}

extension AccountRow {
    /// Alias, else the email's local part: short enough for the menu bar.
    public var shortName: String {
        if let a = alias, !a.isEmpty { return a }
        return email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? email
    }
}

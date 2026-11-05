import Testing
@testable import JustSwapCore

@Suite("Status item title")
struct StatusTitleTests {
    let usage = Usage(fiveHour: UsageWindow(pct: 42.4), sevenDay: UsageWindow(pct: 17.6))

    func title(_ items: MenuBarItems, usage: Usage? = nil, hasActive: Bool = true) -> StatusTitle {
        StatusTitle.compose(items, account: "work", organization: "Acme", usage: usage ?? self.usage, hasActive: hasActive)
    }

    @Test func defaultIsLogoOnly() {
        #expect(title(MenuBarItems()) == StatusTitle(logo: true, text: nil))
    }

    @Test func everyPartInOrder() {
        let all = MenuBarItems(logo: true, account: true, organization: true, fiveHour: true, sevenDay: true)
        #expect(title(all) == StatusTitle(logo: true, text: "work · Acme · 42% · 18%"))
    }

    @Test(arguments: [
        (MenuBarItems(logo: false, fiveHour: true), "42%"),
        (MenuBarItems(logo: false, sevenDay: true), "18%"),
        (MenuBarItems(logo: false, account: true, sevenDay: true), "work · 18%"),
        (MenuBarItems(logo: false, organization: true), "Acme"),
        (MenuBarItems(logo: false, account: true, organization: true), "work · Acme"),
    ])
    func textOnlyCombinations(items: MenuBarItems, text: String) {
        #expect(title(items) == StatusTitle(logo: false, text: text))
    }

    @Test(arguments: [
        (" · ", "work · Acme · 42% · 18%"),
        (" | ", "work | Acme | 42% | 18%"),
        (" / ", "work / Acme / 42% / 18%"),
        (" — ", "work — Acme — 42% — 18%"),
        (" ", "work Acme 42% 18%"),
    ])
    func everyPreset(choice: String, text: String) {
        let all = MenuBarItems(logo: true, account: true, organization: true, fiveHour: true, sevenDay: true)
        let sep = TitleSeparator.resolve(choice: choice, custom: "x")
        #expect(sep == choice)
        #expect(StatusTitle.compose(all, account: "work", organization: "Acme", usage: usage, hasActive: true,
                                    separator: sep) == StatusTitle(logo: true, text: text))
    }

    @Test func customSeparator() {
        #expect(TitleSeparator.resolve(choice: TitleSeparator.customTag, custom: "•") == "•")
        #expect(TitleSeparator.resolve(choice: TitleSeparator.customTag, custom: " ~ ") == " ~ ")
        #expect(TitleSeparator.resolve(choice: TitleSeparator.customTag, custom: "<-->") == "<--")
        let t = StatusTitle.compose(MenuBarItems(logo: false, fiveHour: true, sevenDay: true), account: nil, organization: nil,
                                    usage: usage, hasActive: true,
                                    separator: TitleSeparator.resolve(choice: TitleSeparator.customTag, custom: "•"))
        #expect(t == StatusTitle(logo: false, text: "42%•18%"))
    }

    @Test func emptyCustomOrUnknownChoiceFallsBackToDefault() {
        #expect(TitleSeparator.resolve(choice: TitleSeparator.customTag, custom: "") == " · ")
        #expect(TitleSeparator.resolve(choice: TitleSeparator.customTag, custom: nil) == " · ")
        #expect(TitleSeparator.resolve(choice: nil, custom: "•") == " · ")
        #expect(TitleSeparator.resolve(choice: "??", custom: "•") == " · ")
    }

    @Test func logoWithFiveHour() {
        #expect(title(MenuBarItems(fiveHour: true)) == StatusTitle(logo: true, text: "42%"))
    }

    @Test func everythingOffFallsBackToLogo() {
        let none = MenuBarItems(logo: false)
        #expect(title(none) == StatusTitle(logo: true, text: nil))
    }

    @Test func noActiveSlotFallsBackToLogo() {
        let items = MenuBarItems(logo: false, account: true, fiveHour: true)
        #expect(title(items, hasActive: false) == StatusTitle(logo: true, text: nil))
    }

    @Test func emptyOrganizationIsSkippedAndMissingWindowsDash() {
        let items = MenuBarItems(logo: false, organization: true, fiveHour: true, sevenDay: true)
        let t = StatusTitle.compose(items, account: "work", organization: "", usage: Usage(fiveHour: UsageWindow(pct: nil)),
                                    hasActive: true)
        #expect(t == StatusTitle(logo: false, text: "– · –"))
    }

    @Test func emptyOrganizationAloneFallsBackToLogo() {
        let t = StatusTitle.compose(MenuBarItems(logo: false, organization: true), account: nil, organization: "",
                                    usage: nil, hasActive: true)
        #expect(t == StatusTitle(logo: true, text: nil))
    }

    @Test func migratesOldSettings() {
        #expect(MenuBarItems.migrated(titleMode: "both", showAccountName: false)
            == MenuBarItems(logo: true, account: false, fiveHour: true, sevenDay: true))
        #expect(MenuBarItems.migrated(titleMode: "none", showAccountName: true) == MenuBarItems(account: true))
        #expect(MenuBarItems.migrated(titleMode: "7d", showAccountName: nil) == MenuBarItems(account: true, sevenDay: true))
        #expect(MenuBarItems.migrated(titleMode: nil, showAccountName: false) == MenuBarItems(fiveHour: true))
    }

    @Test func shortNamePrefersAliasThenEmailLocalPart() {
        var row = AccountRow(number: 1, email: "jane.doe@example.com", active: true, usageStatus: "ok")
        #expect(row.shortName == "jane.doe")
        row.alias = ""
        #expect(row.shortName == "jane.doe")
        row.alias = "personal"
        #expect(row.shortName == "personal")
    }
}

import AppKit
import JustSwapCore
import SwiftUI

/// The whole app: header, tabs and the tab content, or an inner page
/// (settings, account tools) with a back control in place of the tabs.
struct PopoverView: View {
    @Bindable var model: AppModel
    @AppStorage(AppPrefs.ignoreDisabled) private var ignoreDisabled = false
    @AppStorage(AppPrefs.showLogTab) private var showLogTab = false
    @State private var refreshHover = false

    var body: some View {
        VStack(spacing: Theme.pad) {
            header
            if let page = model.page {
                PageBar(title: page.title) { model.open(nil) }
            } else {
                tabBar
            }
            // As tall as the content up to 520 pt, then it scrolls. Sized from
            // the content's ideal height, never from a measured state, so the
            // window's size passes cannot feed back into it.
            ScrollView {
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 520)
            .fixedSize(horizontal: false, vertical: true)
            footer
        }
        .padding(.horizontal, Theme.pad)
        .padding(.top, Theme.gap)
        .padding(.bottom, Theme.pad)
        .frame(width: Theme.popoverWidth)
        .background(Theme.background)
        .foregroundStyle(Theme.primary)
        .preferredColorScheme(Theme.scheme)
        .tint(Theme.accent)
        .onChange(of: showLogTab) { _, on in if !on && model.tab == .log { model.tab = .accounts } }
    }

    // MARK: header

    private var header: some View {
        ZStack {
            LogoMark(size: 28)
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Updated")
                        .font(Theme.font(11))
                        .foregroundStyle(Theme.muted)
                    Text(model.loadedAt.map { Format.clock($0, seconds: true) } ?? "—")
                        .font(Theme.figures(11))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
                refreshButton
                HeaderIconButton(icon: "gearshape", help: model.page == .settings ? "Close settings" : "Settings",
                                 selected: model.page == .settings) {
                    model.open(model.page == .settings ? nil : .settings)
                }
            }
        }
        .frame(height: 32)
    }

    /// Probes every slot, or with "Ignore disabled" only the enabled ones
    /// and the active one. A bare glyph that spins while the probe runs.
    private var refreshButton: some View {
        Button {
            Task { await model.refresh() }
        } label: {
            TimelineView(.animation(paused: !model.refreshing)) { tl in
                Image(systemName: "arrow.clockwise")
                    .font(Theme.font(16, .medium))
                    .foregroundStyle(refreshHover || model.refreshing ? Theme.primary : Theme.secondary)
                    .rotationEffect(.degrees(model.refreshing ? spinAngle(tl.date) : 0))
            }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { refreshHover = $0 }
        .animation(Theme.quick, value: refreshHover)
        .help("Refresh")
        .accessibilityLabel("Refresh")
        .accessibilityHint(ignoreDisabled ? "Probes every enabled slot and the active one" : "Probes every slot, disabled ones included")
        .disabled(model.refreshing)
    }

    /// One turn per second.
    private func spinAngle(_ date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360
    }

    // MARK: tabs

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(PopoverTab.visible(showLog: showLogTab)) { t in
                let selected = model.tab == t
                Button {
                    model.tab = t
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: t.icon).font(Theme.font(13))
                        Text(t.title).font(Theme.font(12, .medium))
                    }
                    .foregroundStyle(selected ? Theme.accentInk : Theme.muted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? Theme.raised : .clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(selected ? Theme.hairline : .clear, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
        .animation(Theme.quick, value: model.tab)
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: Theme.pad) {
            if model.page == nil, let err = model.refreshError ?? model.actionError {
                ErrorBanner(text: err)
            }
            switch model.page {
            case .settings: SettingsPage(model: model)
            case .unclaimed: UnclaimedPage(model: model)
            case .mappings: MappingsPage(model: model)
            case .priorities: PrioritiesPage(model: model)
            case .addToken: AddTokenPage(model: model)
            case .purge: PurgePage(model: model)
            case nil:
                switch model.tab {
                case .accounts: AccountsTab(model: model)
                case .autoswitch: AutoswitchTab(model: model)
                case .history: HistoryTab(model: model)
                case .log: LogTab(model: model)
                }
            }
        }
    }

    // MARK: footer

    private var footer: some View {
        FooterButton(title: "Quit just swap", icon: "power") { NSApp.terminate(nil) }
    }
}

/// An icon-only header button: refresh's sibling.
struct HeaderIconButton: View {
    var icon: String
    var help: String
    var selected = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(Theme.font(16, .medium))
                .foregroundStyle(selected ? Theme.accentInk : hover ? Theme.primary : Theme.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Theme.quick, value: hover)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Stands in for the tab bar on an inner page: back control and the page title.
struct PageBar: View {
    var title: String
    var back: () -> Void

    var body: some View {
        HStack(spacing: Theme.gap) {
            Button(action: back) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(Theme.font(12, .semibold))
                    Text("Back").font(Theme.font(12, .medium))
                }
                .foregroundStyle(Theme.accentInk)
                .padding(.horizontal, Theme.gap)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Back")
            Text(title).font(Theme.font(13, .medium)).lineLimit(1)
            Spacer()
        }
        .padding(4)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }
}

struct ErrorBanner: View {
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.gap) {
            Image(systemName: "exclamationmark.triangle").font(Theme.font(12)).foregroundStyle(Theme.warn)
                .frame(width: 16)
            Text(text).font(Theme.font(11)).foregroundStyle(Theme.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(Theme.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warn.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.warn.opacity(0.20), lineWidth: 1))
    }
}

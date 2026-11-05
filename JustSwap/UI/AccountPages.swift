import AppKit
import JustSwapCore
import SwiftUI

/// Credential copies a switch could not attribute to a slot (`cswap unclaimed`).
struct UnclaimedPage: View {
    @Bindable var model: AppModel
    @State private var confirm: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Text("Safety copies of a login that a switch could not tie to a slot. They clear on their own; purge one only when it is stuck. Purging deletes its bytes: recovery is logging in again and Add account.")
                .font(Theme.font(11)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let err = model.pageError { ErrorBanner(text: err) }
            if model.unclaimed.isEmpty {
                EmptyState(icon: "checkmark.circle", text: "No unclaimed credentials")
            } else {
                Card {
                    ForEach(Array(model.unclaimed.enumerated()), id: \.element.id) { i, e in
                        if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                        HStack(spacing: Theme.gap) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.id).font(Theme.mono(11)).lineLimit(1).truncationMode(.middle)
                                Text("slot \(e.slot ?? "?") · \(e.reason ?? "orphaned (no manifest row)")")
                                    .font(Theme.font(10)).foregroundStyle(Theme.muted)
                            }
                            Spacer(minLength: 4)
                            if confirm == e.id {
                                ChipButton(title: "Purge", icon: "trash", tone: Theme.bad) {
                                    confirm = nil
                                    Task {
                                        await model.perform(.purgeUnclaimed(id: e.id))
                                        await model.loadUnclaimed()
                                    }
                                }
                                ChipButton(title: "Cancel", icon: nil) { confirm = nil }
                            } else {
                                ChipButton(title: "Purge…", icon: nil) { confirm = e.id }
                            }
                        }
                    }
                }
            }
        }
        .disabled(model.listBusy)
        .task { await model.loadUnclaimed() }
    }
}

/// Folder → account mappings that `cswap run` uses (`cswap map` / `unmap`).
struct MappingsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            HStack {
                Text("`cswap run` in a mapped folder, or below it, starts Claude Code with that folder's account.")
                    .font(Theme.font(11)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.gap)
                Menu {
                    ForEach(model.accounts.sorted { $0.number < $1.number }) { row in
                        Button(model.label(forSlot: row.number)) { map(row) }
                    }
                } label: {
                    ChipLabel(title: "Map a folder…", icon: "folder.badge.plus", tone: Theme.accentInk)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .disabled(model.accounts.isEmpty)
            }
            if let err = model.pageError { ErrorBanner(text: err) }
            if model.mappings.isEmpty {
                EmptyState(icon: "folder", text: "No folders mapped")
            } else {
                Card {
                    ForEach(Array(model.mappings.enumerated()), id: \.element.id) { i, m in
                        if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                        HStack(spacing: Theme.gap) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.options.redact ? "~/project-\(i + 1)" : abbreviate(m.path))
                                    .font(Theme.mono(11)).lineLimit(1).truncationMode(.head)
                                Text(m.slot.map { model.label(forSlot: $0) } ?? "\(model.options.redact ? "account" : m.email) (removed)")
                                    .font(Theme.font(10)).foregroundStyle(Theme.muted)
                            }
                            Spacer(minLength: 4)
                            ChipButton(title: "Unmap", icon: nil) {
                                Task {
                                    await model.perform(.unmap(path: m.path))
                                    await model.loadMappings()
                                }
                            }
                        }
                    }
                }
            }
        }
        .disabled(model.listBusy)
        .task { await model.loadMappings() }
    }

    private func map(_ row: AccountRow) {
        guard let url = Panels.openFolder(message: "Choose the folder for \(model.name(row))") else { return }
        Task {
            await model.perform(.map(slot: row.number, path: url.path))
            await model.loadMappings()
        }
    }

    private func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

/// Every account with its tier, higher first; only `priority-consume-first` reads them.
struct PrioritiesPage: View {
    @Bindable var model: AppModel

    var body: some View {
        let rows = model.accounts.sorted { ($0.priority ?? 0, -$0.number) > ($1.priority ?? 0, -$1.number) }
        let strategy = model.setting("autoswitch.strategy")?.value.stringValue
        VStack(alignment: .leading, spacing: Theme.gap) {
            Text(strategy == "priority-consume-first"
                 ? "The Priority tiers strategy is on: the engine uses the highest tier first, then the soonest weekly reset within a tier."
                 : "Tiers are read only by the Priority tiers strategy (Autoswitch tab); the current strategy ignores them.")
                .font(Theme.font(11)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let err = model.pageError { ErrorBanner(text: err) }
            Card {
                ForEach(Array(rows.enumerated()), id: \.element.key) { i, row in
                    if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                    HStack(spacing: Theme.gap) {
                        SlotTile(number: row.number, active: row.active, size: 20)
                        Text(model.shortName(row)).font(Theme.font(13, .medium)).lineLimit(1)
                        if !row.isEnabled { Text("disabled").font(Theme.font(10)).foregroundStyle(Theme.muted) }
                        Spacer(minLength: 4)
                        if model.busyAccounts.contains(row.key) {
                            ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12)
                        }
                        TierStepper(tier: row.priority ?? 0) { t in
                            Task { await model.perform(on: row) { .setPriority(slot: $0, tier: t) } }
                        }
                        .disabled(model.busyAccounts.contains(row.key) || model.listBusy)
                    }
                    if let err = model.rowErrors[row.key] {
                        Text(err).font(Theme.font(10)).foregroundStyle(Theme.bad)
                    }
                }
            }
        }
    }
}

/// `cswap add-token -`: a setup-token or an API key, read from stdin.
struct AddTokenPage: View {
    @Bindable var model: AppModel
    @State private var token = ""
    @State private var email = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Text("Paste a setup-token (from `claude setup-token`) or an API key (sk-ant-api…). It goes to the next free slot. A token has no email; add one to tell it apart, or leave it empty.")
                .font(Theme.font(11)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let err = model.pageError { ErrorBanner(text: err) }
            Card {
                FieldLine(label: "Token") {
                    SecureField("sk-ant-…", text: $token).textFieldStyle(.roundedBorder).font(Theme.font(12))
                        .accessibilityLabel("Token")
                }
                if let problem = AccountCommand.tokenProblem(token) {
                    Text(problem).font(Theme.font(10)).foregroundStyle(Theme.bad)
                }
                FieldLine(label: "Email") {
                    TextField("optional", text: $email).textFieldStyle(.roundedBorder).font(Theme.font(12))
                        .accessibilityLabel("Email, optional")
                }
                HStack {
                    Spacer()
                    if model.listBusy { ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12) }
                    ChipButton(title: "Add token", icon: "plus", tone: Theme.accentInk) {
                        let t = token, e = email.trimmingCharacters(in: .whitespaces)
                        Task {
                            if await model.perform(.addToken(token: t, slot: nil, email: e.isEmpty ? nil : e)) {
                                token = ""
                                email = ""
                                model.notice = "Added the token as a new account"
                                model.open(nil)
                                model.tab = .accounts
                            }
                        }
                    }
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || AccountCommand.tokenProblem(token) != nil || model.listBusy)
                }
            }
        }
    }
}

/// `cswap purge` behind a typed confirmation word.
struct PurgePage: View {
    @Bindable var model: AppModel
    @State private var typed = ""
    static let word = "purge"

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Text("Removes every account claude-swap stores: their logins (Keychain items and files), aliases, thresholds, priorities, mappings, usage history and settings. Claude Code stays logged in to its current account. This cannot be undone; Export first to keep a copy.")
                .font(Theme.font(11)).foregroundStyle(Theme.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let err = model.pageError { ErrorBanner(text: err) }
            Card {
                FieldLine(label: "Type \(Self.word)") {
                    TextField(Self.word, text: $typed).textFieldStyle(.roundedBorder).font(Theme.mono(12)).frame(width: 90)
                        .accessibilityLabel("Type \(Self.word) to confirm")
                }
                HStack {
                    Spacer()
                    if model.listBusy { ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12) }
                    ChipButton(title: "Remove all claude-swap data", icon: "trash", tone: Theme.bad) {
                        Task {
                            if await model.perform(.purgeAll) {
                                typed = ""
                                model.notice = "Removed all claude-swap data"
                                model.open(nil)
                            }
                        }
                    }
                    .disabled(typed.trimmingCharacters(in: .whitespaces).lowercased() != Self.word || model.listBusy)
                }
            }
        }
    }
}

//
//  SyncRecoveryPromptView.swift
//  Done
//
//  The one recovery prompt (design §6.6 一次恢复提示, Phase 1 UI): one alert
//  after a catch-up reached head, a read-only list behind 「查看列表」, and
//  the sign-out / erase warning while offers are undecided. The copy is the
//  design's; it never says the server's version is "newer".
//

import SwiftUI

/// Mounts the prompt on the root: the alert appears when the engine
/// publishes a prompt and goes away on any of its three decisions.
struct SyncRecoveryPromptModifier: ViewModifier {
    @ObservedObject var syncService: SupabaseSyncService
    /// The items 「查看列表」 captured from the prompt it was tapped on; non-nil
    /// while the list is up. The prompt itself is untouched meanwhile, so
    /// the alert comes back when the list closes, and the list never
    /// depends on the order SwiftUI runs the button action and the
    /// alert's dismissal in.
    @State private var listItems: [SyncRecoveryItem]?

    private var prompt: SyncRecoveryPrompt? { syncService.recoveryPrompt }

    func body(content: Content) -> some View {
        content
            .alert(
                LCount(.syncRestoreTitleFormat, one: .syncRestoreTitleOne, prompt?.count ?? 0),
                isPresented: Binding(
                    get: { syncService.recoveryPrompt != nil && listItems == nil },
                    // Every way out of the alert is one of its buttons, and
                    // each button's action decides what the prompt becomes
                    // (`later()` only on 「稍后」); nothing is decided here.
                    set: { _ in }
                ),
                presenting: prompt
            ) { prompt in
                Button(L(.syncRestoreWriteBack)) {
                    syncService.presentRecoveryPrompt(nil)
                    Task { await syncService.inbound?.recovery.accept() }
                }
                Button(L(.syncRestoreViewList)) {
                    listItems = prompt.items
                }
                Button(L(.syncRestoreDiscard), role: .destructive) {
                    syncService.inbound?.recovery.discard()
                }
                Button(L(.syncRestoreLater), role: .cancel) {
                    syncService.inbound?.recovery.later()
                }
            } message: { prompt in
                Text(Self.message(for: prompt))
            }
            .sheet(isPresented: Binding(get: { listItems != nil }, set: { shown in if !shown { listItems = nil } })) {
                SyncRecoveryListView(items: listItems ?? [])
                    .environmentObject(syncService)
            }
    }

    static func message(for prompt: SyncRecoveryPrompt) -> String {
        var text = LCount(.syncRestoreMessageFormat, one: .syncRestoreMessageOne, prompt.count)
        if prompt.leaseFailedCount > 0 {
            text += "\n" + LCount(.syncRestoreLeaseFormat, one: .syncRestoreLeaseOne, prompt.leaseFailedCount)
        }
        return text
    }
}

extension View {
    func syncRecoveryPrompt(_ syncService: SupabaseSyncService) -> some View {
        modifier(SyncRecoveryPromptModifier(syncService: syncService))
    }
}

/// 「查看列表」: one row per offered change — title, when this device last
/// edited it, whether the server holds the row now. Read-only; the
/// decisions stay on the alert, which comes back on dismiss.
struct SyncRecoveryListView: View {
    @EnvironmentObject private var syncService: SupabaseSyncService
    @Environment(\.dismiss) private var dismiss
    let items: [SyncRecoveryItem]

    var body: some View {
        NavigationStack {
            List {
                ForEach(items) { item in
                    row(item)
                }
            }
            .navigationTitle(L(.syncRestoreListTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L(.done)) { dismiss() }
                }
            }
        }
    }

    private func row(_ item: SyncRecoveryItem) -> some View {
        let edited: String = item.lastEditedAt.map { Self.formatter.string(from: $0) } ?? "—"
        let serverLine: String = item.serverHasRow ? L(.syncRestoreServerHas) : L(.syncRestoreServerMissing)
        return VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.body)
            HStack {
                Text(L(.syncRestoreLastEdited))
                Spacer()
                Text(edited)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(serverLine)
                .font(.caption)
                .foregroundStyle(item.serverHasRow ? Color.secondary : Color.orange)
        }
        .padding(.vertical, 2)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

/// The sign-out / erase warning (design §6.6 登出 / 擦除前的警告): shown
/// instead of the action while offers are undecided. The destructive button
/// discards the offers, as its title says, and then runs `proceed` — the
/// action the user insisted on.
struct SyncUndecidedOffersWarning: ViewModifier {
    /// Which action the warning stands in front of: the copy names it (sim
    /// QA: the erase path said "signing out").
    enum Action {
        case signOut, erase
    }

    @Binding var isPresented: Bool
    let count: Int
    let action: Action
    let syncService: SupabaseSyncService
    let proceed: () -> Void

    func body(content: Content) -> some View {
        content.alert(L(.syncSignOutWarnTitle), isPresented: $isPresented) {
            Button(L(.cancel), role: .cancel) {}
            Button(L(action == .erase ? .syncEraseAnyway : .syncSignOutAnyway), role: .destructive) {
                syncService.discardUndecidedOffersBeforeLeaving()
                proceed()
            }
        } message: {
            Text(Self.message(action: action, count: count))
        }
    }

    static func message(action: Action, count: Int, language: AppLanguage = .current) -> String {
        switch action {
        case .signOut: return LCount(.syncSignOutWarnFormat, one: .syncSignOutWarnOne, count, language: language)
        case .erase: return LCount(.syncEraseWarnFormat, one: .syncEraseWarnOne, count, language: language)
        }
    }
}

extension View {
    func syncUndecidedOffersWarning(isPresented: Binding<Bool>, count: Int, action: SyncUndecidedOffersWarning.Action,
                                    syncService: SupabaseSyncService, proceed: @escaping () -> Void) -> some View {
        modifier(SyncUndecidedOffersWarning(isPresented: isPresented, count: count, action: action,
                                            syncService: syncService, proceed: proceed))
    }
}

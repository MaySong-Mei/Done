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
    @State private var isShowingList = false

    private var prompt: SyncRecoveryPrompt? { syncService.recoveryPrompt }

    func body(content: Content) -> some View {
        content
            .alert(
                String(format: L(.syncRestoreTitleFormat), prompt?.count ?? 0),
                isPresented: Binding(
                    get: { syncService.recoveryPrompt != nil && !isShowingList },
                    set: { shown in if !shown, !isShowingList { syncService.inbound?.recovery.later() } }
                ),
                presenting: prompt
            ) { prompt in
                Button(L(.syncRestoreWriteBack)) {
                    Task { await syncService.inbound?.recovery.accept() }
                }
                Button(L(.syncRestoreViewList)) {
                    isShowingList = true
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
            .sheet(isPresented: $isShowingList) {
                SyncRecoveryListView(prompt: prompt ?? SyncRecoveryPrompt(count: 0, leaseFailedCount: 0, items: []))
                    .environmentObject(syncService)
            }
    }

    static func message(for prompt: SyncRecoveryPrompt) -> String {
        var text = String(format: L(.syncRestoreMessageFormat), prompt.count)
        if prompt.leaseFailedCount > 0 {
            text += "\n" + String(format: L(.syncRestoreLeaseFormat), prompt.leaseFailedCount)
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
    let prompt: SyncRecoveryPrompt

    var body: some View {
        NavigationStack {
            List {
                ForEach(prompt.items) { item in
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
/// instead of the action while offers are undecided. `proceed` runs the
/// action the user insisted on.
struct SyncUndecidedOffersWarning: ViewModifier {
    @Binding var isPresented: Bool
    let count: Int
    let proceed: () -> Void

    func body(content: Content) -> some View {
        content.alert(L(.syncSignOutWarnTitle), isPresented: $isPresented) {
            Button(L(.cancel), role: .cancel) {}
            Button(L(.syncSignOutAnyway), role: .destructive) { proceed() }
        } message: {
            Text(String(format: L(.syncSignOutWarnFormat), count))
        }
    }
}

extension View {
    func syncUndecidedOffersWarning(isPresented: Binding<Bool>, count: Int, proceed: @escaping () -> Void) -> some View {
        modifier(SyncUndecidedOffersWarning(isPresented: isPresented, count: count, proceed: proceed))
    }
}

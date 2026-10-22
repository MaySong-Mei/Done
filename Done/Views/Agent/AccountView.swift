import SwiftUI
import Combine
import AuthenticationServices

/// What the account card's Sync row says. The master switch gates both
/// directions (design D9), so with it off the device is not connected to
/// anything, whoever owns the data (sim QA round 2: "Connected" over an
/// empty calendar while nothing was pulled).
enum AccountSyncStatus: Equatable {
    case connected
    case syncOff
    /// The owner guard stopped sync (S5); its own card says why.
    case stopped

    static func resolve(masterSwitchOn: Bool, ownerAllowsSync: Bool) -> AccountSyncStatus {
        guard masterSwitchOn else { return .syncOff }
        return ownerAllowsSync ? .connected : .stopped
    }
}

struct AccountView: View {
    @EnvironmentObject private var authService: AuthService
    /// Design §10.7 / S5: the account card shows why sync is stopped — the
    /// account erased elsewhere (and what the user chose), or local data
    /// belonging to another account — and offers the one explicit lift.
    @EnvironmentObject private var syncService: SupabaseSyncService
    /// What "switch to this account" erases with (`LocalDataEraser`, the
    /// same objects Data & Privacy's reset reads).
    @EnvironmentObject private var store: EventStore
    @EnvironmentObject private var skillStore: SkillInsightStore
    @EnvironmentObject private var agentRuntime: AgentRuntime
    @EnvironmentObject private var calendarState: CalendarViewState
    @EnvironmentObject private var imageBackupCoordinator: ImageBackupCoordinator
    @EnvironmentObject private var backupSnapshotService: BackupSnapshotService
    @State private var currentNonce: String?
    @State private var isWarningBeforeSignOut = false
    /// The adopt confirmation (sim QA round 2): the row count is read when
    /// the button is tapped, so the alert names what will actually go up.
    @State private var adoptConfirmationCount: Int?
    /// The switch confirmation: how many rows of the other account leave
    /// this phone, read when the button is tapped.
    @State private var switchConfirmationCount: Int?
    @AppStorage(AppSettingsKeys.syncUploadsEnabled) private var syncUploadsEnabled = true
    @StateObject private var appleCoordinator = AppleSignInCoordinator()

    var body: some View {
        settingsPage(L(.accountTitle)) {
            if authService.isSignedIn {
                signedInSection
            } else {
                // gh#234. The terminal refresh that cleared the session fired
                // during a background sync, likely in a process iOS has since
                // killed — so the explanation has to come off the PERSISTED
                // flag, not off `errorMessage`, which dies with the process
                // and is reset to nil by every sign-in attempt.
                if case .signedOut = syncService.accountCheck {
                    accountGoneCard
                } else if authService.needsReauthentication {
                    sessionEndedCard
                }
                signInSection
            }

            if let error = authService.errorMessage {
                settingsCard {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Signed In

    @ViewBuilder
    private var signedInSection: some View {
        settingsCard(L(.accountTitle)) {
            if let email = authService.session?.user.email {
                settingsLabeledRow(L(.accountEmail), value: email)
            }
            // Monospaced ID — size inherits .subheadline from the card cascade.
            HStack {
                Text(L(.userId))
                Spacer()
                Text(authService.userId?.prefix(8).appending("…") ?? "—")
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
        }

        if case .blocked = syncService.ownerState {
            ownerMismatchCard
        }

        settingsCard(L(.accountSyncSection)) {
            HStack {
                Text(L(.status))
                Spacer()
                switch AccountSyncStatus.resolve(masterSwitchOn: syncUploadsEnabled && !syncService.uploadsBlockedByBuild,
                                                 ownerAllowsSync: syncService.ownerState.allowsSync) {
                case .connected:
                    Label(L(.connectedLabel), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .syncOff:
                    Label(L(.syncOffLabel), systemImage: "pause.circle.fill")
                        .foregroundStyle(.secondary)
                case .stopped:
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(.orange)
                }
            }
            // The quiet badge of the recovery prompt (design §6.6): offers
            // the user has not decided, across relaunches. Tapping it brings
            // the prompt back — the way to write back after 稍后.
            if syncService.pendingPromptCount > 0 {
                Button {
                    syncService.inbound?.recovery.presentAgain()
                } label: {
                    HStack {
                        Label(LCount(.syncPendingWriteBackFormat, one: .syncPendingWriteBackOne, syncService.pendingPromptCount),
                              systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                            .foregroundStyle(.orange)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        settingsHintCard(L(.accountSyncHint))

        settingsDestructiveButton(L(.signOut)) {
            // Design §6.6 登出前的警告: undecided offers block the sign-out
            // until the user confirms losing them.
            if syncService.hasUndecidedOffers {
                isWarningBeforeSignOut = true
            } else {
                authService.signOut()
            }
        }
        .syncUndecidedOffersWarning(isPresented: $isWarningBeforeSignOut, count: syncService.pendingPromptCount,
                                    action: .signOut, syncService: syncService) {
            authService.signOut()
        }
    }

    // MARK: - Account erased elsewhere (design §10.7)

    @ViewBuilder
    private var accountGoneCard: some View {
        settingsCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(accountGoneStatus)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if syncService.accountGoneChoice != .uploadIntoNextAccount {
                Button(L(.accountGoneUploadNext)) {
                    syncService.chooseAfterAccountGone(.uploadIntoNextAccount)
                }
                .font(.subheadline)
            }
        }
    }

    private var accountGoneStatus: String {
        switch syncService.accountGoneChoice {
        case .keepLocalData, .eraseThisDevice: return L(.accountGoneStatusKept)
        case .uploadIntoNextAccount: return L(.accountGoneStatusUploadNext)
        case nil: return L(.accountGoneStatusUndecided)
        }
    }

    // MARK: - Local data belongs to another account (S5)

    @ViewBuilder
    private var ownerMismatchCard: some View {
        settingsCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(ownerMismatchBodyText)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Only for data whose account was erased elsewhere (design §10.7
            // (c)); while that account exists the rows are its own and an
            // upload into this one cannot land (gh#257 staging QA round 4).
            if syncService.canAdoptLocalData {
                Button(L(.ownerMismatchAdopt)) {
                    adoptConfirmationCount = syncService.localIdRowCount
                }
                .font(.subheadline)
                .alert(L(.ownerAdoptConfirmTitle),
                       isPresented: Binding(get: { adoptConfirmationCount != nil },
                                            set: { if !$0 { adoptConfirmationCount = nil } })) {
                    Button(L(.cancel), role: .cancel) {}
                    Button(L(.ownerAdoptConfirmAction)) {
                        syncService.adoptLocalDataForCurrentAccount()
                    }
                } message: {
                    Text(LCount(.ownerAdoptConfirmFormat, one: .ownerAdoptConfirmOne, adoptConfirmationCount ?? 0))
                }
            }
            // Data belongs to its account (gh#257, 2026-10-21): the other
            // account's rows leave this phone, this account's load. With the
            // owner's changes not yet in the cloud (the seamless switch held
            // back) it is "switch anyway" — straight to the switch, the card
            // already said what is lost — and "cancel" ends this session so
            // the owner can sign in and its next flush sends them.
            Group {
                if unsyncedChangesHeld {
                    Button(L(.ownerUnsyncedSwitchAnyway), role: .destructive) {
                        syncService.switchAnyway()
                    }
                    .font(.subheadline)
                    Button(L(.cancel)) {
                        syncService.deferSwitchUntilOwnerSyncs()
                        authService.signOut()
                    }
                    .font(.subheadline)
                } else {
                    Button(L(.ownerMismatchSwitch)) {
                        switchConfirmationCount = syncService.localIdRowCount
                    }
                    .font(.subheadline)
                    Button(L(.signOut)) {
                        authService.signOut()
                    }
                    .font(.subheadline)
                }
            }
            .alert(L(.ownerSwitchConfirmTitle),
                   isPresented: Binding(get: { switchConfirmationCount != nil },
                                        set: { if !$0 { switchConfirmationCount = nil } })) {
                Button(L(.cancel), role: .cancel) {}
                Button(L(.ownerSwitchConfirmAction), role: .destructive) {
                    switchToThisAccount()
                }
            } message: {
                Text(LCount(.ownerSwitchConfirmFormat, one: .ownerSwitchConfirmOne, switchConfirmationCount ?? 0))
            }
        }
    }

    /// The sign-in did not switch on its own: the owner still has changes
    /// that are not in the cloud (`ownerUnsyncedChanges`). Not in the
    /// "erased elsewhere" state, whose three choices stay as they were.
    private var unsyncedChangesHeld: Bool {
        !syncService.canAdoptLocalData && syncService.ownerUnsyncedChanges != nil
    }

    private var ownerMismatchBodyText: String {
        if syncService.canAdoptLocalData { return L(.ownerMismatchGoneBody) }
        if let unsynced = syncService.ownerUnsyncedChanges {
            return LCount(.ownerUnsyncedFormat, one: .ownerUnsyncedOne, unsynced)
        }
        return L(.ownerMismatchBody)
    }

    /// The existing erase, keeping this session, then a fresh sync of it.
    private func switchToThisAccount() {
        let eraser = LocalDataEraser(store: store, skillStore: skillStore, agentRuntime: agentRuntime,
                                     authService: authService, calendarState: calendarState, syncService: syncService,
                                     imageBackupCoordinator: imageBackupCoordinator,
                                     backupSnapshotService: backupSnapshotService)
        syncService.switchToCurrentAccount {
            eraser.resetAllLocalData(keepingSession: true)
        }
    }

    // MARK: - Session ended (gh#234)

    @ViewBuilder
    private var sessionEndedCard: some View {
        settingsCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(L(.sessionEndedNeedsReauth))
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Sign In

    @ViewBuilder
    private var signInSection: some View {
        settingsCard {
            VStack(spacing: 16) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue)

                Text(L(.signInToSyncShort))
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }

        Button {
            startAppleSignIn()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 16))
                Text(L(.signInWithApple))
                    .font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .foregroundStyle(.primary)
            .contentShape(Capsule())
            .background(Color.black.opacity(0.001), in: Capsule())
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(authService.isLoading)

        Button {
            Task { await authService.signInWithGoogle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "g.circle.fill")
                    .font(.system(size: 16))
                Text(L(.signInWithGoogle))
                    .font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .foregroundStyle(.primary)
            .contentShape(Capsule())
            .background(Color.black.opacity(0.001), in: Capsule())
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(authService.isLoading)
    }

    // MARK: - Apple Sign In

    private func startAppleSignIn() {
        let nonce = AuthService.randomNonce()
        currentNonce = nonce
        appleCoordinator.onCompletion = { result in
            handleAppleSignIn(result)
        }
        appleCoordinator.start(hashedNonce: AuthService.sha256(nonce))
    }

    // MARK: - Apple Sign In Handler

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let idTokenData = credential.identityToken,
                  let idToken = String(data: idTokenData, encoding: .utf8),
                  let nonce = currentNonce
            else {
                authService.errorMessage = "Failed to get Apple ID token"
                return
            }
            Task {
                await authService.signInWithApple(idToken: idToken, nonce: nonce)
            }
        case .failure(let error):
            if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                authService.errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - MCP URL Section

private struct MCPURLSection: View {
    @EnvironmentObject private var authService: AuthService
    @AppStorage(AppSettingsKeys.mcpURL) private var savedURL: String = ""
    @State private var isGenerating = false
    @State private var isRevealed = false
    @State private var copied = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if savedURL.isEmpty {
                // No URL yet — show setup button
                Button {
                    generate()
                } label: {
                    HStack {
                        if isGenerating {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "link.badge.plus")
                                .foregroundStyle(.purple)
                        }
                        Text(L(.setUpAiConnection))
                            .foregroundStyle(.primary)
                    }
                }
                .disabled(isGenerating)

                Text(L(.generateConnectorHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // URL exists — show masked/revealed with actions
                HStack {
                    Image(systemName: "link")
                        .foregroundStyle(.purple)
                    Text(L(.aiConnectorUrl))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Label(L(.activeStatus), systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                Text(isRevealed ? savedURL : maskedURL)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(isRevealed ? nil : 1)
                    .truncationMode(.middle)

                HStack(spacing: 16) {
                    Button {
                        isRevealed.toggle()
                    } label: {
                        Label(isRevealed ? L(.hideLabel) : L(.revealLabel), systemImage: isRevealed ? "eye.slash" : "eye")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Button {
                        UIPasteboard.general.string = savedURL
                        // Remembered so "Reset all local data" can clear the
                        // clipboard — this URL carries a live read token, and
                        // the erase removing `mcpURL` from `UserDefaults` left
                        // it one paste away on a phone the user believes is
                        // erased. See `AppSettingsKeys.mcpURLPasteboardChangeCount`.
                        UserDefaults.standard.set(
                            UIPasteboard.general.changeCount,
                            forKey: AppSettingsKeys.mcpURLPasteboardChangeCount
                        )
                        copied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            copied = false
                        }
                    } label: {
                        Label(copied ? L(.copiedLabel) : L(.copyLabel), systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(copied ? .green : .purple)

                    Spacer()

                    Button {
                        generate()
                    } label: {
                        Label(L(.regenerateLabel), systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            if let error = errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private var maskedURL: String {
        guard let range = savedURL.range(of: "token=") else { return "••••••••" }
        let prefix = savedURL[...range.lowerBound]
        return prefix + "dk_••••••••••••"
    }

    private func generate() {
        isGenerating = true
        errorMessage = nil
        Task {
            do {
                let url = try await authService.generatePermanentMCPURL()
                savedURL = url.absoluteString
                isGenerating = false
            } catch {
                isGenerating = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - AI Snapshot Button

private struct AISnapshotButton: View {
    @EnvironmentObject private var authService: AuthService
    @State private var isGenerating = false
    @State private var copied = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                generate()
            } label: {
                HStack {
                    if isGenerating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: copied ? "checkmark.circle.fill" : "link.badge.plus")
                            .foregroundStyle(copied ? .green : .blue)
                    }
                    Text(copied ? "Link copied!" : "Generate AI Context Link")
                        .foregroundStyle(copied ? .green : .primary)
                }
            }
            .disabled(isGenerating)

            Text(L(.ephemeralLinkHint))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private func generate() {
        isGenerating = true
        errorMessage = nil
        Task {
            do {
                let url = try await authService.generateSnapshotURL()
                UIPasteboard.general.string = url.absoluteString
                isGenerating = false
                copied = true
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                copied = false
            } catch {
                isGenerating = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Connections View

struct ConnectionsView: View {
    @EnvironmentObject private var authService: AuthService

    var body: some View {
        settingsPage(L(.connections)) {
            settingsCard(L(.aiConnector)) {
                MCPURLSection()
                    .environmentObject(authService)
            }
            settingsHintCard(L(.hintAiConnector))

            settingsCard(L(.aiSnapshot)) {
                AISnapshotButton()
                    .environmentObject(authService)
            }
            settingsHintCard(L(.hintAiSnapshot))
        }
    }
}

// MARK: - Apple Sign In Coordinator

private final class AppleSignInCoordinator: NSObject, ObservableObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    var onCompletion: ((Result<ASAuthorization, Error>) -> Void)?

    func start(hashedNonce: String) {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.email]
        request.nonce = hashedNonce
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        onCompletion?(.success(authorization))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        onCompletion?(.failure(error))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}


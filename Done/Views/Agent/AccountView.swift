import SwiftUI
import Combine
import AuthenticationServices

struct AccountView: View {
    @EnvironmentObject private var authService: AuthService
    @State private var currentNonce: String?
    @StateObject private var appleCoordinator = AppleSignInCoordinator()

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if authService.isSignedIn {
                    signedInSection
                } else {
                    signInSection
                }

                if let error = authService.errorMessage {
                    GlassCardView(cornerRadius: 16, contentPadding: 14) {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Signed In

    @ViewBuilder
    private var signedInSection: some View {
        GlassCardView(cornerRadius: 16, contentPadding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Account")
                    .font(.headline)
                if let email = authService.session?.user.email {
                    HStack {
                        Text("Email")
                        Spacer()
                        Text(email)
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
                HStack {
                    Text("User ID")
                    Spacer()
                    Text(authService.userId?.prefix(8).appending("…") ?? "—")
                        .foregroundStyle(.secondary)
                        .font(.system(.subheadline, design: .monospaced))
                }
                .font(.subheadline)
            }
        }

        GlassCardView(cornerRadius: 16, contentPadding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Sync")
                    .font(.headline)
                HStack {
                    Text("Status")
                    Spacer()
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .font(.subheadline)
                Text("Your events, logs, and skills sync automatically to the cloud. AI assistants can query this data via MCP.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        Button(role: .destructive) {
            authService.signOut()
        } label: {
            Text("Sign Out")
                .font(.headline)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .contentShape(Capsule())
                .background(Color.black.opacity(0.001), in: Capsule())
                .glassEffect(.regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sign In

    @ViewBuilder
    private var signInSection: some View {
        GlassCardView(cornerRadius: 16, contentPadding: 14) {
            VStack(spacing: 16) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue)

                Text("Sign in to sync")
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
                Text("Sign in with Apple")
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
                Text("Sign in with Google")
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
    @AppStorage("mcpURL") private var savedURL: String = ""
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
                        Text("Set Up AI Connection")
                            .foregroundStyle(.primary)
                    }
                }
                .disabled(isGenerating)

                Text("Generate a permanent URL to connect Claude, ChatGPT, or other AI apps to your Done data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // URL exists — show masked/revealed with actions
                HStack {
                    Image(systemName: "link")
                        .foregroundStyle(.purple)
                    Text("AI Connector URL")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Label("Active", systemImage: "checkmark.circle.fill")
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
                        Label(isRevealed ? "Hide" : "Reveal", systemImage: isRevealed ? "eye.slash" : "eye")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Button {
                        UIPasteboard.general.string = savedURL
                        copied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied!" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(copied ? .green : .purple)

                    Spacer()

                    Button {
                        generate()
                    } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
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

            Text("Creates a 5-minute link with your schedule and activity data. Paste it into ChatGPT or Claude.")
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
        settingsPage("Connections") {
            settingsCard("AI Connector") {
                MCPURLSection()
                    .environmentObject(authService)
            }
            settingsHintCard("A permanent URL that lets Claude, ChatGPT, or other AI apps read your Done data on demand to help you plan.")

            settingsCard("AI Snapshot") {
                AISnapshotButton()
                    .environmentObject(authService)
            }
            settingsHintCard("A short-lived link containing your recent schedule and activity. Paste it into a fresh AI conversation.")
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


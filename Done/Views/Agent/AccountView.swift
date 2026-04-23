import SwiftUI
import Combine
import AuthenticationServices

struct AccountView: View {
    @EnvironmentObject private var authService: AuthService
    @State private var currentNonce: String?
    @StateObject private var appleCoordinator = AppleSignInCoordinator()

    var body: some View {
        Form {
            if authService.isSignedIn {
                signedInSection
            } else {
                signInSection
            }

            if let error = authService.errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Signed In

    @ViewBuilder
    private var signedInSection: some View {
        Section("Account") {
            if let email = authService.session?.user.email {
                HStack {
                    Text("Email")
                    Spacer()
                    Text(email)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("User ID")
                Spacer()
                Text(authService.userId?.prefix(8).appending("…") ?? "—")
                    .foregroundStyle(.secondary)
                    .font(.system(.body, design: .monospaced))
            }
        }

        Section("Sync") {
            HStack {
                Text("Status")
                Spacer()
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
            }
            Text("Your events, logs, and skills sync automatically to the cloud. AI assistants can query this data via MCP.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Section {
            MCPConnectButton()
                .environmentObject(authService)
        }

        Section {
            AISnapshotButton()
                .environmentObject(authService)
        }

        Section {
            Button("Sign Out", role: .destructive) {
                authService.signOut()
            }
        }
    }

    // MARK: - Sign In

    @ViewBuilder
    private var signInSection: some View {
        Section {
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

        Section {
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
                .frame(height: 28)
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(authService.isLoading)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        }

        Section {
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
                .frame(height: 28)
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(authService.isLoading)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        }
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

// MARK: - MCP Connect Button

private struct MCPConnectButton: View {
    @EnvironmentObject private var authService: AuthService
    @State private var isGenerating = false
    @State private var code: String? = nil
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                generate()
            } label: {
                HStack {
                    if isGenerating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "cpu")
                            .foregroundStyle(.purple)
                    }
                    Text("Generate AI Connect Code")
                        .foregroundStyle(.primary)
                }
            }
            .disabled(isGenerating)

            if let code {
                HStack(spacing: 12) {
                    Text(code)
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundStyle(.purple)
                        .tracking(8)
                    Button {
                        UIPasteboard.general.string = code
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
            }

            Text("Connects Claude.ai or ChatGPT to your account. Enter this code in the AI's browser popup. Valid 5 minutes.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let error = errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private func generate() {
        isGenerating = true
        errorMessage = nil
        code = nil
        Task {
            do {
                let newCode = try await authService.generateMCPConnectCode()
                isGenerating = false
                code = newCode
                // Auto-clear after 5 min
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                code = nil
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
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let error = errorMessage {
                Text(error)
                    .font(.footnote)
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


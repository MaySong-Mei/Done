import SwiftUI
import AuthenticationServices

struct AccountView: View {
    @EnvironmentObject private var authService: AuthService
    @State private var currentNonce: String?

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
            MCPURLSection()
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
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)

                Text("Sign in to sync")
                    .font(.headline)

                Text("Connect your account to sync your life data to the cloud. This lets AI assistants understand your patterns and provide personalized insights.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }

        Section {
            SignInWithAppleButton(.signIn) { request in
                let nonce = AuthService.randomNonce()
                currentNonce = nonce
                request.requestedScopes = [.email]
                request.nonce = AuthService.sha256(nonce)
            } onCompletion: { result in
                handleAppleSignIn(result)
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 50)

            Button {
                Task { await authService.signInWithGoogle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "g.circle.fill")
                        .font(.system(size: 20))
                    Text("Sign in with Google")
                        .font(.system(size: 17, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color(.systemBackground))
                .foregroundStyle(.primary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(authService.isLoading)
        }

        Section("Email Sign In") {
            DevSignInView()
                .environmentObject(authService)
        }
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
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                // URL exists — show masked/revealed with actions
                HStack {
                    Image(systemName: "link")
                        .foregroundStyle(.purple)
                    Text("AI Connector URL")
                        .font(.subheadline.weight(.medium))
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
                Text(error).font(.footnote).foregroundStyle(.red)
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

// MARK: - Email Sign In

private struct DevSignInView: View {
    @EnvironmentObject private var authService: AuthService
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        TextField("Email", text: $email)
            .textContentType(.emailAddress)
            .autocapitalization(.none)
        SecureField("Password", text: $password)
            .textContentType(.password)

        HStack {
            Button("Sign In") {
                Task { await authService.signInWithEmail(email, password: password) }
            }
            .disabled(email.isEmpty || password.isEmpty)

            Button("Sign Up") {
                Task { await authService.signUp(email: email, password: password) }
            }
            .disabled(email.isEmpty || password.isEmpty)
        }
    }
}

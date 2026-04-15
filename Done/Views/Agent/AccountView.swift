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

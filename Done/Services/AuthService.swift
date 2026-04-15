import Foundation
import AuthenticationServices
import Combine
import CryptoKit

// MARK: - Auth State

struct AuthUser: Codable, Equatable {
    let id: String          // Supabase user UUID
    let email: String?
    let createdAt: String?
}

struct AuthSession: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let user: AuthUser
}

// MARK: - Auth Service

/// Manages Supabase Auth via REST API. No external SDK dependency.
/// Supports Apple Sign In and email/password (for testing).
@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var session: AuthSession?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    var isSignedIn: Bool { session != nil }
    var userId: String? { session?.user.id }
    var accessToken: String? { session?.accessToken }

    private let supabaseURL: String
    private let supabaseAnonKey: String
    private let sessionKey = "supabaseAuthSession"
    private let defaults: UserDefaults

    init(
        url: String = SupabaseSyncConfig.url,
        anonKey: String = SupabaseSyncConfig.anonKey,
        defaults: UserDefaults = .standard
    ) {
        self.supabaseURL = url
        self.supabaseAnonKey = anonKey
        self.defaults = defaults
        loadSession()
    }

    // MARK: - Apple Sign In

    /// Call this with the result of ASAuthorizationController.
    func signInWithApple(
        idToken: String,
        nonce: String
    ) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let body: [String: Any] = [
                "provider": "apple",
                "id_token": idToken,
                "nonce": nonce,
            ]
            let result = try await postAuth(
                path: "/auth/v1/token?grant_type=id_token",
                body: body
            )
            let session = try parseSessionResponse(result)
            self.session = session
            saveSession()
            print("[Auth] Signed in as \(session.user.id)")
        } catch {
            errorMessage = error.localizedDescription
            print("[Auth] Apple Sign In failed: \(error)")
        }
    }

    // MARK: - Email Sign In (for development/testing)

    func signInWithEmail(_ email: String, password: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let body: [String: Any] = [
                "email": email,
                "password": password,
            ]
            let result = try await postAuth(
                path: "/auth/v1/token?grant_type=password",
                body: body
            )
            let session = try parseSessionResponse(result)
            self.session = session
            saveSession()
            print("[Auth] Signed in as \(session.user.email ?? session.user.id)")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signUp(email: String, password: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let body: [String: Any] = [
                "email": email,
                "password": password,
            ]
            let result = try await postAuth(path: "/auth/v1/signup", body: body)
            // signup may auto-login or require email confirmation
            if let accessToken = result["access_token"] as? String {
                let session = try parseSessionResponse(result)
                self.session = session
                saveSession()
            } else {
                errorMessage = nil // signed up, but needs confirmation
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Token Refresh

    func refreshTokenIfNeeded() async {
        guard let session else { return }
        // Refresh if within 5 minutes of expiry
        guard session.expiresAt.timeIntervalSinceNow < 300 else { return }

        do {
            let body: [String: Any] = [
                "refresh_token": session.refreshToken,
            ]
            let result = try await postAuth(
                path: "/auth/v1/token?grant_type=refresh_token",
                body: body
            )
            let newSession = try parseSessionResponse(result)
            self.session = newSession
            saveSession()
            print("[Auth] Token refreshed")
        } catch {
            print("[Auth] Token refresh failed: \(error)")
            // Don't sign out — let the user retry
        }
    }

    // MARK: - Sign Out

    func signOut() {
        session = nil
        defaults.removeObject(forKey: sessionKey)
        print("[Auth] Signed out")
    }

    // MARK: - Nonce generation for Apple Sign In

    static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length
        while remainingLength > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            _ = SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms)
            for random in randoms {
                guard remainingLength > 0 else { break }
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }
        return result
    }

    static func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Persistence

    private func saveSession() {
        guard let session else { return }
        if let data = try? JSONEncoder().encode(session) {
            defaults.set(data, forKey: sessionKey)
        }
    }

    private func loadSession() {
        guard let data = defaults.data(forKey: sessionKey),
              let saved = try? JSONDecoder().decode(AuthSession.self, from: data)
        else { return }
        session = saved
    }

    // MARK: - HTTP Helpers

    private func postAuth(path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: "\(supabaseURL)\(path)") else {
            throw AuthError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.invalidResponse
        }

        if http.statusCode >= 400 {
            let msg = json["error_description"] as? String
                ?? json["msg"] as? String
                ?? json["message"] as? String
                ?? "Authentication failed (HTTP \(http.statusCode))"
            throw AuthError.serverError(msg)
        }
        return json
    }

    private func parseSessionResponse(_ json: [String: Any]) throws -> AuthSession {
        guard let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String,
              let expiresIn = json["expires_in"] as? Int,
              let userDict = json["user"] as? [String: Any],
              let userId = userDict["id"] as? String
        else {
            throw AuthError.invalidResponse
        }
        let user = AuthUser(
            id: userId,
            email: userDict["email"] as? String,
            createdAt: userDict["created_at"] as? String
        )
        return AuthSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            user: user
        )
    }

    enum AuthError: Error, LocalizedError {
        case invalidURL
        case invalidResponse
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid URL"
            case .invalidResponse: return "Invalid response"
            case .serverError(let msg): return msg
            }
        }
    }
}

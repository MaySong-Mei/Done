//
//  GoogleCalendarService.swift
//  Done
//
//  Created by Yifan Mei on 12/10/25.
//

import Foundation
import AuthenticationServices
import CryptoKit
import Combine
import UIKit

@MainActor
class GoogleCalendarService: NSObject, ObservableObject {
    nonisolated(unsafe) static let shared = GoogleCalendarService()

    @Published var isAuthenticated = false
    @Published var userEmail: String?

    private var calendarColors: [String: CalendarColor] = [:]
    private var colorsLastFetched: Date?

    private let clientID = "263767104090-p66p0btql0p72rih94ger7f426q653no.apps.googleusercontent.com"
    private var clientIDBase: String { clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "") }
    private var callbackScheme: String { "com.googleusercontent.apps.\(clientIDBase)" }
    private var redirectURI: String { "\(callbackScheme):/oauth2redirect" }
    private let scopes = [
        "https://www.googleapis.com/auth/calendar",
        "https://www.googleapis.com/auth/userinfo.email"
    ]

    private let tokenKey = "googleAccessToken"
    private let refreshTokenKey = "googleRefreshToken"
    private let expiryKey = "googleTokenExpiry"
    private let emailKey = "googleUserEmail"

    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date?

    private nonisolated override init() {
        super.init()
        Task { @MainActor in
            self.loadTokens()
        }
    }

    private func loadTokens() {
        accessToken = UserDefaults.standard.string(forKey: tokenKey)
        refreshToken = UserDefaults.standard.string(forKey: refreshTokenKey)
        userEmail = UserDefaults.standard.string(forKey: emailKey)

        if let expiryInterval = UserDefaults.standard.object(forKey: expiryKey) as? TimeInterval {
            tokenExpiry = Date(timeIntervalSince1970: expiryInterval)
        }

        isAuthenticated = accessToken != nil && refreshToken != nil
    }

    private func saveTokens() {
        if let accessToken = accessToken {
            UserDefaults.standard.set(accessToken, forKey: tokenKey)
        }
        if let refreshToken = refreshToken {
            UserDefaults.standard.set(refreshToken, forKey: refreshTokenKey)
        }
        if let tokenExpiry = tokenExpiry {
            UserDefaults.standard.set(tokenExpiry.timeIntervalSince1970, forKey: expiryKey)
        }
        if let userEmail = userEmail {
            UserDefaults.standard.set(userEmail, forKey: emailKey)
        }

        isAuthenticated = accessToken != nil && refreshToken != nil
    }

    func signOut() {
        accessToken = nil
        refreshToken = nil
        tokenExpiry = nil
        userEmail = nil

        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: refreshTokenKey)
        UserDefaults.standard.removeObject(forKey: expiryKey)
        UserDefaults.standard.removeObject(forKey: emailKey)

        isAuthenticated = false
    }

    func authenticate(presentationAnchor: ASPresentationAnchor) async throws {
        guard !clientID.isEmpty else {
            throw GoogleCalendarError.configurationError("Client ID not configured")
        }

        let state = UUID().uuidString
        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        guard let url = components.url else {
            throw GoogleCalendarError.invalidURL
        }

        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let callbackURL = callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: GoogleCalendarError.authenticationFailed)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw GoogleCalendarError.authenticationFailed
        }

        try await exchangeCodeForTokens(code: code, codeVerifier: codeVerifier)
    }

    private func exchangeCodeForTokens(code: String, codeVerifier: String) async throws {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let parameters = [
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier
        ]

        request.httpBody = urlFormBody(from: parameters)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw GoogleCalendarError.tokenExchangeFailed
        }

        guard let tokenResponse = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            let bodyString = String(data: data, encoding: .utf8) ?? "<unreadable>"
            throw GoogleCalendarError.apiError("Token decode failed: \(bodyString)")
        }
        accessToken = tokenResponse.accessToken
        refreshToken = tokenResponse.refreshToken
        tokenExpiry = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))

        try await fetchUserInfo()
        saveTokens()
    }

    private func fetchUserInfo() async throws {
        guard let accessToken = accessToken else { return }

        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleCalendarError.apiError("Userinfo failed: no HTTP response")
        }

        let bodyString = String(data: data, encoding: .utf8) ?? "<unreadable>"

        guard httpResponse.statusCode == 200 else {
            throw GoogleCalendarError.apiError("Userinfo failed (\(httpResponse.statusCode)): \(bodyString)")
        }

        guard let userInfo = try? JSONDecoder().decode(UserInfo.self, from: data) else {
            throw GoogleCalendarError.apiError("Userinfo decode failed: \(bodyString)")
        }
        userEmail = userInfo.email
    }

    private func refreshAccessToken() async throws {
        guard let refreshToken = refreshToken else {
            throw GoogleCalendarError.noRefreshToken
        }

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let parameters = [
            "client_id": clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]

        request.httpBody = urlFormBody(from: parameters)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw GoogleCalendarError.tokenExchangeFailed
        }

        guard let tokenResponse = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            let bodyString = String(data: data, encoding: .utf8) ?? "<unreadable>"
            throw GoogleCalendarError.apiError("Refresh decode failed: \(bodyString)")
        }

        accessToken = tokenResponse.accessToken
        tokenExpiry = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        saveTokens()
    }

    private func getValidAccessToken() async throws -> String {
        if let tokenExpiry = tokenExpiry, Date() > tokenExpiry {
            try await refreshAccessToken()
        }

        guard let accessToken = accessToken else {
            throw GoogleCalendarError.notAuthenticated
        }

        return accessToken
    }

    func syncTimeEntry(_ entry: TimeEntry) async {
        guard isAuthenticated else { return }

        do {
            let token = try await getValidAccessToken()
            try await createCalendarEvent(entry: entry, accessToken: token)
        } catch {
            print("Failed to sync time entry: \(error)")
        }
    }

    // 同步所有未同步的事件
    func syncPendingEntries() async {
        guard isAuthenticated else { return }

        let dataManager = DataManager.shared
        let unsyncedEntries = dataManager.timeEntries.filter { !$0.syncedToCalendar && $0.endTime != nil }

        guard !unsyncedEntries.isEmpty else { return }

        print("Found \(unsyncedEntries.count) unsynced entries, attempting to sync...")

        for entry in unsyncedEntries {
            await syncTimeEntry(entry)
        }
    }

    private func createCalendarEvent(entry: TimeEntry, accessToken: String) async throws {
        guard let endTime = entry.endTime else { return }

        let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let colorId = await getCalendarColorId(from: entry.colorHex)

        let event: [String: Any] = [
            "summary": entry.templateName,
            "start": [
                "dateTime": ISO8601DateFormatter().string(from: entry.startTime)
            ],
            "end": [
                "dateTime": ISO8601DateFormatter().string(from: endTime)
            ],
            "colorId": colorId
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: event)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw GoogleCalendarError.apiError("Failed to create calendar event")
        }
    }

    private func getCalendarColorId(from hexColor: String) async -> String {
        // 优先使用预定义的颜色键映射（精确匹配）
        let colorKey = CategoryColorKey.from(hex: hexColor)
        let category = ColorSystem.Category.color(for: colorKey)

        // 如果 hex 匹配预定义颜色键，直接返回对应的 googleColorId
        if hexColor.uppercased() == colorKey.hexValue.uppercased() {
            return category.googleColorId
        }

        // 否则使用最近邻匹配（支持自定义颜色）
        if calendarColors.isEmpty || shouldRefreshColors() {
            await fetchCalendarColors()
        }

        guard !calendarColors.isEmpty else {
            return category.googleColorId  // 降级到默认值
        }

        return findNearestColorId(for: hexColor)
    }

    private func shouldRefreshColors() -> Bool {
        guard let lastFetched = colorsLastFetched else { return true }
        return Date().timeIntervalSince(lastFetched) > 86400
    }

    private func fetchCalendarColors() async {
        guard let accessToken = try? await getValidAccessToken() else { return }

        let url = URL(string: "https://www.googleapis.com/calendar/v3/colors")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return
            }

            if let colorsResponse = try? JSONDecoder().decode(CalendarColorsResponse.self, from: data) {
                self.calendarColors = colorsResponse.event
                self.colorsLastFetched = Date()
            }
        } catch {
            print("Failed to fetch calendar colors: \(error)")
        }
    }

    private func findNearestColorId(for hexColor: String) -> String {
        guard let targetColor = parseHexColor(hexColor) else {
            return "9"
        }

        var nearestId = "9"
        var minDistance = Double.infinity

        for (colorId, calendarColor) in calendarColors {
            guard let bgColor = parseHexColor(calendarColor.background) else { continue }

            let distance = colorDistance(targetColor, bgColor)
            if distance < minDistance {
                minDistance = distance
                nearestId = colorId
            }
        }

        return nearestId
    }

    private func parseHexColor(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0

        guard Scanner(string: hex).scanHexInt64(&int) else { return nil }

        let r, g, b: UInt64
        switch hex.count {
        case 3:
            (r, g, b) = ((int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default:
            return nil
        }

        return (Double(r), Double(g), Double(b))
    }

    private func colorDistance(_ color1: (r: Double, g: Double, b: Double),
                               _ color2: (r: Double, g: Double, b: Double)) -> Double {
        let rDiff = color1.r - color2.r
        let gDiff = color1.g - color2.g
        let bDiff = color1.b - color2.b

        return sqrt(2 * rDiff * rDiff + 4 * gDiff * gDiff + 3 * bDiff * bDiff)
    }

    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        guard let data = verifier.data(using: .utf8) else { return "" }
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private func urlFormBody(from parameters: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.query?.data(using: .utf8)
    }
}

extension GoogleCalendarService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return MainActor.assumeIsolated {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = windowScene.windows.first else {
                return ASPresentationAnchor()
            }
            return window
        }
    }
}

struct TokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

struct UserInfo: Codable {
    let email: String
}

struct CalendarColor: Codable {
    let background: String
    let foreground: String
}

struct CalendarColorsResponse: Codable {
    let event: [String: CalendarColor]
}

enum GoogleCalendarError: LocalizedError {
    case configurationError(String)
    case invalidURL
    case authenticationFailed
    case tokenExchangeFailed
    case notAuthenticated
    case noRefreshToken
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .configurationError(let message):
            return "Configuration error: \(message)"
        case .invalidURL:
            return "Invalid URL"
        case .authenticationFailed:
            return "Authentication failed"
        case .tokenExchangeFailed:
            return "Failed to exchange code for tokens"
        case .notAuthenticated:
            return "Not authenticated"
        case .noRefreshToken:
            return "No refresh token available"
        case .apiError(let message):
            return "API error: \(message)"
        }
    }
}

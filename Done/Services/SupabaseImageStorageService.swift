import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Done",
    category: "ImageStorage"
)

/// Supabase Storage client scoped to the `event-images` bucket. This is the
/// L2 image-backup layer per the architecture in issue #21 — cross-platform,
/// cross-Apple-ID recoverable, our cost.
///
/// **Auth model** (intentionally different from `SupabaseSyncService`):
///
/// `SupabaseSyncService` currently sends the project's service_role key in
/// both `apikey` and `Authorization: Bearer ...` headers, which bypasses RLS
/// entirely — the per-user isolation it provides is enforced application-side
/// only. That's a pre-existing security debt tracked separately.
///
/// This service does it correctly: `apikey` carries the project key (for
/// project routing) and `Authorization` carries the **user's session JWT**,
/// so the RLS policies on `storage.objects` (`auth.uid()` checks on the path
/// prefix) actually enforce isolation at the database. Anyone with the
/// embedded project key can no longer read other users' images.
///
/// **DEBUG safety**: respects `uploadsDisabled` so simulator runs with a real
/// Apple ID can't pollute the production bucket. Read paths stay live.
@MainActor
final class SupabaseImageStorageService {
    static let bucket = "event-images"

    private let url: String
    private let projectAPIKey: String
    private weak var authService: AuthService?

    /// Mirrors `SupabaseSyncService.uploadsDisabled` — flipped on for DEBUG.
    /// Reads are always allowed. Public so the sync-status UI can label the
    /// Images channel as "disabled (DEBUG)" instead of falsely claiming
    /// successful uploads from simulator runs.
    // ⚠️ TEMPORARY BYPASS FOR REAL-DEVICE TESTING — DO NOT COMMIT
    // Restore the #if DEBUG block below after the device build is on hardware.
    static let uploadsDisabled = false
    // #if DEBUG
    // static let uploadsDisabled = true
    // #else
    // static let uploadsDisabled = false
    // #endif

    init(
        url: String = SupabaseSyncConfig.url,
        projectAPIKey: String = SupabaseSyncConfig.anonKey,
        authService: AuthService
    ) {
        self.url = url
        self.projectAPIKey = projectAPIKey
        self.authService = authService
    }

    // MARK: - Public API

    /// Path convention `event-images/{user_id}/{eventID}/{imageID}.jpg`.
    /// First path segment MUST be the user_id — RLS depends on it.
    func storagePath(userID: String, eventID: UUID, imageID: UUID) -> String {
        "\(userID)/\(eventID.uuidString)/\(imageID.uuidString).jpg"
    }

    /// Upload an image's bytes. Caller is responsible for compression; we
    /// just pipe the bytes through. Throws `Error.uploadsDisabled` in DEBUG
    /// so callers can no-op without surprising error logs.
    ///
    /// Returns `true` when the bytes were actually written this call, `false`
    /// when the object was already present in the cloud at this exact path
    /// (a 409 dedup outcome — Supabase wraps that as HTTP 400 + body 409,
    /// see `effectiveStatusCode`). Callers want this distinction so the
    /// `Scan: N uploaded, M dedup'd` accounting reflects reality instead of
    /// claiming N new uploads when nothing actually went over the wire.
    @discardableResult
    func upload(path: String, data: Data, contentType: String = "image/jpeg") async throws -> Bool {
        if Self.uploadsDisabled {
            throw Error.uploadsDisabled
        }
        // Don't let a 0-byte local file silently become a 0-byte cloud
        // "image". `Data(contentsOf:)` on a truncated/corrupt file returns
        // empty bytes without erroring; we'd otherwise upload garbage.
        guard !data.isEmpty else {
            throw Error.emptyData
        }
        // Refresh the JWT if it's close to expiry — a long upload that
        // started with <5 min validity would otherwise 401 mid-flight.
        await authService?.refreshTokenIfNeeded()
        guard let token = authService?.accessToken else {
            throw Error.notSignedIn
        }
        guard let requestURL = URL(string: "\(url)/storage/v1/object/\(Self.bucket)/\(path)") else {
            throw Error.invalidPath(path)
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue(projectAPIKey, forHTTPHeaderField: "apikey")
        // ↓ User JWT, not the project key. This is what makes RLS work.
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        // x-upsert: false (default) so we don't silently overwrite when the
        // same image ID is uploaded twice. Forces 409 instead and we can
        // detect and skip.
        request.setValue("false", forHTTPHeaderField: "x-upsert")
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.networkFailure
        }
        let effective = Self.effectiveStatusCode(httpStatus: http.statusCode, body: responseData)

        if effective == 409 {
            // Object already exists at this path — treat as success since
            // image IDs are UUIDs (uniqueness is on us; collision means we
            // already uploaded the same image earlier).
            logger.info("Image already uploaded, skipping: \(path, privacy: .private)")
            return false
        }

        guard (200..<300).contains(effective) else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            logger.error("Upload failed (\(effective, privacy: .public)): \(body.prefix(200), privacy: .public)")
            throw Error.httpFailure(status: effective)
        }
        return true
    }

    /// Download an image's bytes. Returns nil if the object doesn't exist
    /// (HTTP 404) — caller can interpret that as "not yet uploaded" rather
    /// than a hard failure.
    func download(path: String) async throws -> Data? {
        await authService?.refreshTokenIfNeeded()
        guard let token = authService?.accessToken else {
            throw Error.notSignedIn
        }
        guard let requestURL = URL(string: "\(url)/storage/v1/object/\(Self.bucket)/\(path)") else {
            throw Error.invalidPath(path)
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue(projectAPIKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.networkFailure
        }
        let effective = Self.effectiveStatusCode(httpStatus: http.statusCode, body: data)
        if effective == 404 {
            return nil
        }
        guard (200..<300).contains(effective) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            logger.error("Download failed (\(effective, privacy: .public)): \(body.prefix(200), privacy: .public)")
            throw Error.httpFailure(status: effective)
        }
        return data
    }

    /// Supabase Storage's REST endpoint wraps real status codes inside the
    /// response body and returns HTTP 400 at the transport layer:
    ///
    ///     HTTP 400 + body `{"statusCode":"404", ...}`  → not found
    ///     HTTP 400 + body `{"statusCode":"409", ...}`  → duplicate
    ///     HTTP 400 + body `{"statusCode":"413", ...}`  → payload too large
    ///
    /// Without unwrapping the body, every error looks like a generic 400 and
    /// callers can't branch on the real semantics (treat 404 as nil-continue,
    /// treat 409 as already-uploaded success, surface 413 to the user, etc.).
    /// This helper decodes the wrapped status when the outer code is non-2xx.
    /// Returns the outer code unchanged on 2xx responses, or when the body
    /// isn't the expected shape.
    private static func effectiveStatusCode(httpStatus: Int, body: Data) -> Int {
        if (200..<300).contains(httpStatus) { return httpStatus }
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let raw = json["statusCode"] as? String,
           let parsed = Int(raw) {
            return parsed
        }
        return httpStatus
    }

    /// Delete one or more images. Best-effort — partial failures log and
    /// proceed rather than throw, so a single missing key doesn't block the
    /// rest of an event-deletion cleanup.
    func delete(paths: [String]) async {
        if Self.uploadsDisabled { return }
        guard !paths.isEmpty else { return }
        guard let token = authService?.accessToken else { return }

        // Supabase Storage's REST DELETE endpoint accepts a JSON body
        // `{ "prefixes": [...] }` for batch delete on
        // `/storage/v1/object/<bucket>`. One round trip per call.
        guard let requestURL = URL(string: "\(url)/storage/v1/object/\(Self.bucket)") else { return }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "DELETE"
        request.setValue(projectAPIKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["prefixes": paths])

        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                let body = String(data: responseData, encoding: .utf8) ?? ""
                logger.error("Delete (\(paths.count, privacy: .public) paths) HTTP \(http.statusCode, privacy: .public): \(body.prefix(200), privacy: .public)")
            }
        } catch {
            logger.error("Delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    enum Error: Swift.Error, LocalizedError {
        case notSignedIn
        case uploadsDisabled
        case emptyData
        case invalidPath(String)
        case networkFailure
        case httpFailure(status: Int)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Sign in before backing up images to the cloud."
            case .uploadsDisabled:
                return "Image uploads are disabled in this build (DEBUG safety net)."
            case .emptyData:
                return "Refusing to upload an empty (0-byte) image."
            case .invalidPath(let p):
                return "Invalid storage path: \(p)"
            case .networkFailure:
                return "Network failure during image storage call."
            case .httpFailure(let s):
                return "Image storage call failed (HTTP \(s))"
            }
        }
    }
}

import Foundation
import Security

// MARK: - Session store seam

/// Where `AuthService` keeps the serialized session between launches.
///
/// The seam exists for two reasons. The production store is the Keychain
/// (gh#249: the session must not ride along in backups), and the Keychain is
/// neither unit-testable in isolation nor shared between tests without
/// leaking state across them; and every one of the gh#249 data-preservation
/// gates is about what `AuthService` does when THIS layer fails, which is
/// only observable with a store that can be told to fail.
///
/// Contract: `load()` returns `nil` when nothing is stored and THROWS when
/// the store cannot answer — the two are different facts and the caller
/// treats them differently. `save` overwrites. `delete` of an absent item is
/// not an error.
protocol AuthSessionStore: AnyObject {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func delete() throws
}

// MARK: - Keychain

/// A `SecItem` call that did not succeed, carrying the status for the log.
struct KeychainSessionStoreError: Error, CustomStringConvertible {
    let operation: String
    let status: OSStatus

    var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "\(operation) failed: \(status) (\(message))"
    }
}

/// The production store: one generic-password item, scoped to this app.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is the load-bearing
/// attribute and both halves matter:
///
/// - `ThisDeviceOnly` keeps the item OUT of iCloud/iTunes backups and out of
///   Quick Start migration. A session restored onto a second device would
///   share one refresh-token family with the first; GoTrue's reuse detection
///   then revokes the family on both, which is the failure gh#234's forensics
///   recorded and this attribute is the cause-level fix for.
/// - `AfterFirstUnlock`, not `WhenUnlocked`: background refresh has to read
///   the token while the screen is locked.
///
/// `save` updates in place and only adds when nothing is there; it never
/// deletes first. A delete-then-add has a window in which a crash leaves no
/// session at all, and gh#249 forbids the store from ever being the reason a
/// user is signed out.
final class KeychainSessionStore: AuthSessionStore {
    let service: String
    let account: String

    init(
        service: String = (Bundle.main.bundleIdentifier ?? "Done") + ".auth",
        account: String = "supabaseAuthSession"
    ) {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainSessionStoreError(operation: "SecItemCopyMatching", status: status)
        }
    }

    func save(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            let addStatus = SecItemAdd(baseQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainSessionStoreError(operation: "SecItemAdd", status: addStatus)
            }
        default:
            throw KeychainSessionStoreError(operation: "SecItemUpdate", status: updateStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainSessionStoreError(operation: "SecItemDelete", status: status)
        }
    }
}

// MARK: - In-memory

/// Test double with the same contract and no persistence beyond the object.
/// Two `AuthService`s that should see each other's writes (a "relaunch")
/// share one instance.
final class InMemorySessionStore: AuthSessionStore {
    private(set) var stored: Data?

    init(stored: Data? = nil) {
        self.stored = stored
    }

    func load() throws -> Data? { stored }
    func save(_ data: Data) throws { stored = data }
    func delete() throws { stored = nil }
}

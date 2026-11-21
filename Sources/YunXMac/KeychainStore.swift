// macOS adaptation for YunX; see the repository LICENSE for AGPL-3.0 terms.
import Combine
import Foundation
import Security

private enum YunXKeychain {
    static let service = "cn.workbuddy.yunx.macos"

    static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func save(_ data: Data, account: String) throws {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(key as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var create = key
            create[kSecValueData as String] = data
            create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(create as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        "无法安全保存凭证到 macOS 钥匙串（错误码 \(status)）。"
    }
}

@MainActor
final class QuarkCredentialStore: ObservableObject {
    static let shared = QuarkCredentialStore()
    private static let accountKey = "quark-account-cookie"

    @Published private(set) var isSignedIn: Bool

    private init() {
        isSignedIn = YunXKeychain.load(account: Self.accountKey) != nil
    }

    func cookie() -> String? {
        guard let data = YunXKeychain.load(account: Self.accountKey),
              let value = String(data: data, encoding: .utf8),
              Self.isValid(value) else { return nil }
        return value
    }

    func save(cookie: String) throws {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValid(trimmed) else { throw CredentialError.invalidCookie }
        guard let data = trimmed.data(using: .utf8) else { throw CredentialError.encoding }
        try YunXKeychain.save(data, account: Self.accountKey)
        isSignedIn = true
    }

    func clear() {
        YunXKeychain.delete(account: Self.accountKey)
        isSignedIn = false
    }

    private static func isValid(_ cookie: String) -> Bool {
        var values: [String: String] = [:]
        for part in cookie.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            values[String(pair[0])] = String(pair[1])
        }
        return !(values["__pus"] ?? "").isEmpty && !(values["__puus"] ?? "").isEmpty
    }
}

private enum CredentialError: LocalizedError {
    case invalidCookie
    case encoding

    var errorDescription: String? {
        switch self {
        case .invalidCookie:
            "Cookie 缺少夸克登录所需的 __pus 或 __puus 字段。请在夸克网盘完成登录后再保存。"
        case .encoding:
            "无法编码夸克登录凭证。"
        }
    }
}

enum DownloadHeaderVault {
    private static func key(_ id: UUID) -> String { "download-secrets-\(id.uuidString)" }

    private struct DownloadSecrets: Codable {
        var headers: [String: String]
        var sourceURL: String?
    }

    static func save(_ headers: [String: String], sourceURL: String? = nil, for id: UUID) throws {
        let secrets = DownloadSecrets(headers: headers, sourceURL: sourceURL)
        guard let data = try? JSONEncoder().encode(secrets) else { throw VaultError.encoding }
        try YunXKeychain.save(data, account: key(id))
    }

    static func headers(for id: UUID) -> [String: String] {
        guard let secrets = load(for: id) else { return [:] }
        return secrets.headers
    }

    static func sourceURL(for id: UUID) -> String? {
        load(for: id)?.sourceURL
    }

    static func hasProtectedSourceURL(for id: UUID) -> Bool {
        load(for: id)?.sourceURL != nil
    }

    static func remove(for id: UUID) {
        YunXKeychain.delete(account: key(id))
    }

    static func hasSensitiveHeaders(_ headers: [String: String]) -> Bool {
        headers.keys.contains { ["cookie", "authorization", "proxy-authorization"].contains($0.lowercased()) }
    }

    private static func load(for id: UUID) -> DownloadSecrets? {
        guard let data = YunXKeychain.load(account: key(id)) else { return nil }
        return try? JSONDecoder().decode(DownloadSecrets.self, from: data)
    }

    private enum VaultError: LocalizedError {
        case encoding
        var errorDescription: String? { "无法安全编码下载凭证。" }
    }
}

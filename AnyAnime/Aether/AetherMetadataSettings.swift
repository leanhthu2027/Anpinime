import Foundation
#if canImport(Security)
import Security
#endif

/// The app's metadata credential is supplied privately at build time. Its value
/// is never shown by Settings, stored in UserDefaults or sent to the video host.
enum AetherMetadataSettings {
    static let languageKey = "AnPinime.vipMetadataLanguage"
    static let attribution = "Danh mục và thông tin phim: TMDB. Video và phụ đề: Aether."
    private static let service = "com.xemphim.aipinime.metadata"
    private static let account = "tmdb-read-access"
    static var configured: Bool { credential() != nil }
    static func credential() -> String? {
        let bundleURL = Bundle.main.url(forResource: "MetadataCredentials", withExtension: "plist")
            ?? Bundle.main.url(forResource: "MetadataCredentials", withExtension: "plist", subdirectory: "Private")
        return configuredCredential(environment: ProcessInfo.processInfo.environment,
                                    stored: storedCredential(), bundleURL: bundleURL)
    }

    /// The transport and resource seam makes precedence and the packaged default
    /// testable without touching the user's Keychain or real credential.
    static func configuredCredential(environment: [String: String], stored: String?, bundleURL: URL?) -> String? {
        if let value = value(in: environment) { return value }
        if let bundleURL, let data = try? Data(contentsOf: bundleURL), data.count <= 32 * 1024,
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
           let value = value(in: plist) { return value }
        // Older versions exposed a token field. A stale saved value must not
        // override the verified default shipped by this version.
        return clean(stored)
    }

    private static func value(in settings: [String: String]) -> String? {
        if let token = clean(settings["TMDB_READ_TOKEN"]) { return token }
        guard let key = clean(settings["TMDB_API_KEY"]),
              key.range(of: #"^[a-fA-F0-9]{32}$"#, options: .regularExpression) != nil else { return nil }
        return key
    }

    private static func storedCredential() -> String? {
        #if canImport(Security)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8) else { return nil }
        return clean(value)
        #else
        return nil
        #endif
    }
    static func saveCredential(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty || clean(value) != nil else { throw AetherCatalogError.invalidCredential }
        #if canImport(Security)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AetherCatalogError.secureStorage }
        } else {
            let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                item.merge(attributes) { _, new in new }
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AetherCatalogError.secureStorage }
            } else if status != errSecSuccess { throw AetherCatalogError.secureStorage }
        }
        #else
        throw AetherCatalogError.secureStorage
        #endif
    }
    private static func clean(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              value.utf8.count <= 8192, !value.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return value
    }
}

enum AetherCatalogError: LocalizedError {
    case missingCredential, invalidCredential, secureStorage, invalidData, invalidRoute, unavailable, http(Int)
    var errorDescription: String? {
        switch self {
        case .missingCredential: return "Bản cài đặt thiếu cấu hình danh mục phim. Hãy cập nhật bản Anpinime mới nhất."
        case .invalidCredential: return "Cấu hình danh mục phim chưa được TMDB chấp nhận. Hãy cập nhật bản Anpinime mới nhất."
        case .secureStorage: return "Chưa lưu được thông tin truy cập vào Keychain."
        case .invalidData: return "Thông tin phim chưa đầy đủ. Hãy thử tải lại."
        case .invalidRoute: return "Đường dẫn danh mục hoặc tập phim không hợp lệ."
        case .unavailable: return "Chưa kết nối được máy chủ thông tin phim TMDB. Hãy thử lại."
        case .http(let code): return "TMDB trả lỗi HTTP \(code). Hãy thử lại sau."
        }
    }
}

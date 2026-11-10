import Foundation
#if canImport(Security)
import Security
#endif

/// TMDB credentials belong to the user, as in Streambert. Never ship a copied
/// provider key, persist one in UserDefaults, or forward it to the video host.
enum AetherMetadataSettings {
    static let languageKey = "AnPinime.vipMetadataLanguage"
    static let attribution = "Danh mục và thông tin phim: TMDB. Video và phụ đề: Aether."
    private static let service = "com.xemphim.aipinime.metadata"
    private static let account = "tmdb-read-access"
    static var configured: Bool { credential() != nil }
    static func credential() -> String? {
        for name in ["TMDB_READ_TOKEN", "TMDB_API_KEY"] {
            if let value = clean(ProcessInfo.processInfo.environment[name]) { return value }
        }
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
        case .missingCredential: return "Thêm TMDB API Read Access Token trong Cài đặt → Anpinime VIP để tải danh mục phim."
        case .invalidCredential: return "Thông tin truy cập TMDB chưa hợp lệ. Hãy kiểm tra trong Cài đặt → Anpinime VIP."
        case .secureStorage: return "Chưa lưu được thông tin truy cập vào Keychain."
        case .invalidData: return "Thông tin phim chưa đầy đủ. Hãy thử tải lại."
        case .invalidRoute: return "Đường dẫn danh mục hoặc tập phim không hợp lệ."
        case .unavailable: return "Chưa kết nối được máy chủ thông tin phim TMDB. Hãy thử lại."
        case .http(let code): return "TMDB trả lỗi HTTP \(code). Hãy thử lại sau."
        }
    }
}

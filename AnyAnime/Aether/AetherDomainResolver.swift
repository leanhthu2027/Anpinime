import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Discovery is data, never executable configuration. Only aether.<ASCII TLD>
/// origins explicitly listed by the official document can extend the seed list.
enum AetherDomainPolicy {
    static let directory = URL(string: "https://rentry.co/aetherdomains")!
    // User-supplied historical snapshot, NOT a claim of current availability.
    static let seeds = ["aether.st", "aether.ist", "aether.cx", "aether.bar"]
    static let defaultURL = URL(string: "https://aether.st/")!
    static let manualKey = "AnPinime.aetherDomain"

    static func origin(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased(),
              host.range(of: #"^aether\.[a-z]{2,24}$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: "https://" + host + "/")
    }

    static func manualOrigin(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil else { return nil }
        return origin(url)
    }

    /// Handles Markdown, plain text and HTML hrefs, without a table/DOM contract.
    static func domains(in document: String) -> [URL] {
        guard document.utf8.count <= 512 * 1024,
              let pattern = try? NSRegularExpression(pattern: #"https://[^\s<>\"'`\)\]\}]+"#, options: .caseInsensitive) else { return [] }
        let text = document as NSString
        var seen = Set<String>()
        return pattern.matches(in: document, range: NSRange(location: 0, length: text.length)).compactMap { match in
            let raw = text.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
            guard let url = manualOrigin(raw), let host = url.host, seen.insert(host).inserted else { return nil }
            return url
        }.prefix(8).map { $0 }
    }

    static func permitsNavigation(_ url: URL, pinnedOrigin: URL) -> Bool {
        guard let origin = origin(url) else { return false }
        return origin == pinnedOrigin
    }
}

enum AetherError: LocalizedError {
    case invalidDomain, unavailable, browserRequired, invalidPage
    var errorDescription: String? {
        switch self {
        case .invalidDomain: return "Chọn tên miền HTTPS có trong danh sách Aether chính thức; không kèm đường dẫn hoặc tham số."
        case .unavailable: return "Chưa kết nối được các tên miền Aether. Hãy thử lại hoặc chọn tên miền trong Cài đặt."
        case .browserRequired: return "Duyệt, tìm kiếm, chọn phim và tập trực tiếp trong Aether."
        case .invalidPage: return "Không mở được trang này trong phiên Aether hiện tại."
        }
    }
}

/// Check each redirect BEFORE following it, not just the final response URL.
final class AetherRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let hosts: Set<String>
    private var redirects = 0
    private let lock = NSLock()
    init(hosts: Set<String>) { self.hosts = hosts }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        redirects += 1
        let withinLimit = redirects <= 3
        lock.unlock()
        guard withinLimit, let url = request.url, url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), hosts.contains(host) else { completionHandler(nil); return }
        completionHandler(request)
    }
}

actor AetherDomainResolver {
    struct Selection: Equatable {
        let origin: URL
        let verifiedHosts: Set<String>
    }
    private struct DirectoryCache: Codable { let domains: [URL]; let date: Date }
    private struct WorkingCache: Codable { let origin: URL; let date: Date }
    static let shared = AetherDomainResolver()
    private let session: URLSession
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let directoryKey = "AnPinime.aetherDirectory.v1"
    private let workingKey = "AnPinime.aetherWorkingDomain.v1"
    private let directoryTTL: TimeInterval = 6 * 3600
    private let workingTTL: TimeInterval = 3600
    private var selection: Selection?
    private var selectedAt = Date.distantPast
    private var directoryAttemptAt = Date.distantPast

    init(session: URLSession? = nil, defaultsSuiteName: String? = nil,
         now: @escaping @Sendable () -> Date = { Date() }) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        configuration.httpShouldSetCookies = false
        self.session = session ?? URLSession(configuration: configuration)
        self.defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.now = now
    }

    func setManualDomain(_ text: String) async throws {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { defaults.removeObject(forKey: AetherDomainPolicy.manualKey) }
        else {
            guard let url = AetherDomainPolicy.manualOrigin(clean) else { throw AetherError.invalidDomain }
            let verified = await officialDomains(force: false)
            try Task.checkCancellation()
            guard verified.contains(url) else { throw AetherError.invalidDomain }
            defaults.set(url.absoluteString, forKey: AetherDomainPolicy.manualKey)
        }
        selection = nil
    }

    /// Resolve only before creating a browser session. The browser pins this
    /// result until the user explicitly ends/retries that session.
    func resolve(force: Bool = false) async throws -> Selection {
        try Task.checkCancellation()
        let date = now()
        let manual = defaults.string(forKey: AetherDomainPolicy.manualKey)
        if !force, let selection, date.timeIntervalSince(selectedAt) >= 0,
           date.timeIntervalSince(selectedAt) < workingTTL,
           manual == nil || AetherDomainPolicy.manualOrigin(manual!) == selection.origin { return selection }
        let domains = await officialDomains(force: force)
        try Task.checkCancellation()
        let hosts = Set(domains.compactMap(\.host))
        var candidates = domains
        if let manual, !manual.isEmpty {
            guard let url = AetherDomainPolicy.manualOrigin(manual), domains.contains(url) else { throw AetherError.invalidDomain }
            candidates = [url] // A manual choice never silently switches source.
        } else if !force, let data = defaults.data(forKey: workingKey),
                  let cache = try? JSONDecoder().decode(WorkingCache.self, from: data),
                  date.timeIntervalSince(cache.date) >= 0, date.timeIntervalSince(cache.date) < workingTTL,
                  domains.contains(cache.origin) {
            candidates = [cache.origin] + domains.filter { $0 != cache.origin }
        }
        for candidate in candidates.prefix(8) {
            try Task.checkCancellation()
            do {
                let (body, response) = try await fetch(candidate, hosts: hosts)
                guard (200..<300).contains(response.statusCode), let final = response.url,
                      let origin = AetherDomainPolicy.origin(final), domains.contains(origin),
                      let html = String(data: body, encoding: .utf8),
                      html.range(of: #"(?i)<(?:!doctype\s+html|html)\b"#, options: .regularExpression) != nil,
                      !html.lowercased().contains("cf-chl-"), !html.lowercased().contains("<title>just a moment") else { continue }
                let result = Selection(origin: origin, verifiedHosts: hosts)
                selection = result; selectedAt = date
                defaults.set(try JSONEncoder().encode(WorkingCache(origin: origin, date: date)), forKey: workingKey)
                return result
            } catch {
                try Task.checkCancellation()
                if (error as? URLError)?.code == .cancelled { throw error }
            }
        }
        throw AetherError.unavailable
    }

    private func officialDomains(force: Bool) async -> [URL] {
        let date = now()
        let cached = defaults.data(forKey: directoryKey).flatMap { try? JSONDecoder().decode(DirectoryCache.self, from: $0) }
        // Bounded offline grace. Persisted strings still pass the same host policy.
        let usable = cached.flatMap { cache -> [URL]? in
            guard date.timeIntervalSince(cache.date) >= 0, date.timeIntervalSince(cache.date) < 7 * 86400 else { return nil }
            return cache.domains.prefix(8).compactMap { AetherDomainPolicy.manualOrigin($0.absoluteString) }
        } ?? []
        var discovered = usable
        let age = cached.map { date.timeIntervalSince($0.date) } ?? .infinity
        if force || (age >= directoryTTL || age < 0) && date.timeIntervalSince(directoryAttemptAt) >= 60 {
            directoryAttemptAt = date
            if let (data, response) = try? await fetch(AetherDomainPolicy.directory, hosts: ["rentry.co"]),
               response.statusCode == 200, response.url?.host == "rentry.co",
               response.url?.path == AetherDomainPolicy.directory.path,
               let text = String(data: data, encoding: .utf8) {
                let parsed = AetherDomainPolicy.domains(in: text)
                if !parsed.isEmpty {
                    discovered = parsed
                    if let data = try? JSONEncoder().encode(DirectoryCache(domains: parsed, date: date)) { defaults.set(data, forKey: directoryKey) }
                }
            }
        }
        let seeds = AetherDomainPolicy.seeds.compactMap { URL(string: "https://" + $0 + "/") }
        return discovered + seeds.filter { !discovered.contains($0) }
    }

    private func fetch(_ url: URL, hosts: Set<String>) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.setValue("text/html,text/plain;q=0.9", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request, delegate: AetherRedirectGuard(hosts: hosts))
        try Task.checkCancellation()
        guard data.count <= 512 * 1024, let http = response as? HTTPURLResponse,
              let final = http.url, final.scheme == "https", final.user == nil, final.password == nil,
              final.port == nil || final.port == 443, let host = final.host?.lowercased(), hosts.contains(host) else { throw AetherError.invalidDomain }
        return (data, http)
    }
}

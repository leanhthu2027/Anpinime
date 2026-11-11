import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct AetherSubtitle: Identifiable, Hashable {
    let id: String
    let title: String
    let language: String
    let url: URL
    let headers: [String: String]

    init(id: String? = nil, title: String, language: String, url: URL, headers: [String: String] = [:]) {
        self.id = id ?? "aether-sub-" + AetherSubtitleClient.fingerprint(url.absoluteString)
        self.title = title
        self.language = AetherSubtitleClient.languageCode(language.isEmpty ? title : language)
        self.url = url
        self.headers = headers.filter { key, value in
            ["user-agent", "referer", "origin", "accept", "accept-language"].contains(key.lowercased()) &&
                !key.contains(where: { $0 == "\r" || $0 == "\n" }) &&
                !value.contains(where: { $0 == "\r" || $0 == "\n" })
        }
    }
}

enum AetherSubtitleError: LocalizedError {
    case invalidURL, unavailable, tooLarge, invalidFormat, translationFailed
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Địa chỉ phụ đề không hợp lệ."
        case .unavailable: return "Máy chủ phụ đề chưa phản hồi. Bạn có thể chọn bản khác hoặc tải lại."
        case .tooLarge: return "File phụ đề vượt quá 8 MB."
        case .invalidFormat: return "Phụ đề này chưa có định dạng văn bản được hỗ trợ."
        case .translationFailed: return "Dịch phụ đề chưa hoàn tất. Bản gốc vẫn được giữ; hãy thử lại."
        }
    }
}

/// Native client for the exact external subtitle sources and Google translation
/// transport used by Aether's current release. No website or HTML player is run.
final class AetherSubtitleClient {
    private let session: URLSession
    private let folder: URL
    private static let maximumBytes = 8 * 1024 * 1024

    init(session: URLSession? = nil, cacheDirectory: URL? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        config.httpShouldSetCookies = false
        self.session = session ?? URLSession(configuration: config)
        self.folder = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AetherSubtitles", isDirectory: true)
    }

    /// Failure of an optional external index never discards stream-provided tracks.
    /// Calls are bounded to the two account-free indices shipped by Aether.
    func external(mediaType: String, id: Int, season: Int? = nil, episode: Int? = nil, imdbID: String? = nil) async -> [AetherSubtitle] {
        guard id > 0, mediaType == "movie" || mediaType == "tv" else { return [] }
        if mediaType == "tv", season == nil || episode == nil || (season ?? -1) < 0 || (episode ?? 0) <= 0 { return [] }
        let path = mediaType == "tv" ? "tv/\(id)/\(season!)/\(episode!)" : "movie/\(id)"
        async let nova = index(URL(string: "https://sub.vdrk.site/v1/" + path)!, source: "nova")
        async let opensubs = openSubtitles(imdbID: imdbID, season: mediaType == "tv" ? season : nil,
                                           episode: mediaType == "tv" ? episode : nil)
        let combined = await nova + opensubs
        guard !Task.isCancelled else { return [] }
        return Self.preferred(combined)
    }

    private func openSubtitles(imdbID: String?, season: Int?, episode: Int?) async -> [AetherSubtitle] {
        guard let imdbID, imdbID.range(of: #"^tt[0-9]{5,12}$"#, options: .regularExpression) != nil else { return [] }
        let prefix = episode.map { "episode-\($0)/" } ?? ""
        let suffix = season.map { "/season-\($0)" } ?? ""
        let url = URL(string: "https://rest.opensubtitles.org/search/" + prefix + "imdbid-" + imdbID.dropFirst(2) + suffix)!
        return await index(url, source: "opensubs")
    }

    private func index(_ url: URL, source: String) async -> [AetherSubtitle] {
        do {
            var request = URLRequest(url: url)
            request.httpShouldHandleCookies = false
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if source == "opensubs" { request.setValue("VLSub 0.10.2", forHTTPHeaderField: "X-User-Agent") }
            let data = try await download(request, maximum: 2 * 1024 * 1024)
            return Self.decodeIndex(data, source: source)
        } catch { return [] }
    }

    static func decodeIndex(_ data: Data, source: String) -> [AetherSubtitle] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count <= 1000 else { return [] }
        return rows.compactMap { row in
            let label: String, raw: String, language: String
            if source == "opensubs" {
                guard let value = row["SubDownloadLink"] as? String, let name = row["LanguageName"] as? String else { return nil }
                // Aether requests an uncompressed UTF-8 subtitle from this route.
                raw = value.replacingOccurrences(of: ".gz", with: "")
                    .replacingOccurrences(of: "download/", with: "download/subencoding-utf8/")
                language = row["ISO639"] as? String ?? name
                label = name + " · OpenSubtitles"
            } else {
                guard let value = row["file"] as? String, let name = row["label"] as? String else { return nil }
                raw = value; label = name + " · Aether"; language = name
            }
            guard let url = URL(string: raw), validRemote(url) else { return nil }
            return AetherSubtitle(title: label, language: language, url: url)
        }
    }

    static func preferred(_ subtitles: [AetherSubtitle]) -> [AetherSubtitle] {
        var seen = Set<URL>()
        return subtitles.filter { seen.insert($0.url).inserted }
            .enumerated().sorted { left, right in
                func rank(_ code: String) -> Int { code == "vi" ? 0 : code == "en" ? 1 : 2 }
                let l = rank(left.element.language), r = rank(right.element.language)
                return l == r ? left.offset < right.offset : l < r
            }.map(\.element)
    }

    func materialize(_ subtitle: AetherSubtitle) async throws -> URL {
        guard Self.validRemote(subtitle.url) else { throw AetherSubtitleError.invalidURL }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = folder.appendingPathComponent(Self.fingerprint(subtitle.url.absoluteString))
        for ext in ["srt", "vtt", "ass"] {
            let existing = stem.appendingPathExtension(ext)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: existing.path),
               let date = attributes[.modificationDate] as? Date, Date().timeIntervalSince(date) < 86400,
               let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumBytes { return existing }
        }
        var request = URLRequest(url: subtitle.url)
        request.httpShouldHandleCookies = false
        request.setValue("text/plain,text/vtt,application/x-subrip,*/*;q=0.5", forHTTPHeaderField: "Accept")
        subtitle.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let data = try await download(request)
        guard var text = String(data: data, encoding: .utf8) else { throw AetherSubtitleError.invalidFormat }
        text = text.replacingOccurrences(of: "\u{FEFF}", with: "")
        let ext: String
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT") { ext = "vtt" }
        else if !Self.cues(text).isEmpty { ext = "srt" }
        else if text.contains("[Events]") && text.contains("Dialogue:") { ext = "ass" }
        else { throw AetherSubtitleError.invalidFormat }
        try Task.checkCancellation()
        let output = stem.appendingPathExtension(ext)
        try Data(text.utf8).write(to: output, options: .atomic)
        return output
    }

    /// Uses Aether's existing Google Translate provider. Only cue text is sent;
    /// indices, timings and VTT settings are preserved in their original positions.
    func translateToVietnamese(_ localFile: URL, progress: @escaping (Double) -> Void = { _ in }) async throws -> URL {
        guard localFile.isFileURL,
              let size = (try? localFile.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size <= Self.maximumBytes else { throw AetherSubtitleError.tooLarge }
        let original = try String(contentsOf: localFile, encoding: .utf8)
        var lines = Self.normalizedLines(original)
        let entries = Self.cues(original)
        guard !entries.isEmpty, entries.count <= 20000 else { throw AetherSubtitleError.invalidFormat }
        let output = localFile.deletingPathExtension().appendingPathExtension("vi." + localFile.pathExtension)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: output.path),
           let date = attributes[.modificationDate] as? Date, Date().timeIntervalSince(date) < 86400 {
            progress(1); return output
        }
        progress(0)
        var start = 0
        while start < entries.count {
            try Task.checkCancellation()
            var end = start, bytes = 0
            while end < entries.count, end - start < 25 {
                let count = entries[end].text.utf8.count
                if end > start, bytes + count > 2000 { break }
                guard count <= 16000 else { throw AetherSubtitleError.invalidFormat }
                bytes += count; end += 1
            }
            let batch = Array(entries[start..<end])
            let translations = try await translateBatch(batch.map(\.text))
            guard translations.count == batch.count else { throw AetherSubtitleError.translationFailed }
            // Keep line count stable until every original cue has been replaced.
            for (cue, translation) in zip(batch, translations) {
                lines[cue.start] = translation
                if cue.end > cue.start + 1 { for index in (cue.start + 1)..<cue.end { lines[index] = "" } }
            }
            start = end; progress(Double(start) / Double(entries.count))
            // Same bounded pacing as the site's single-provider translation path.
            if start < entries.count { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        try Task.checkCancellation()
        try Data(lines.joined(separator: "\n").utf8).write(to: output, options: .atomic)
        return output
    }

    private func translateBatch(_ values: [String]) async throws -> [String] {
        let marker = "__ANPINIME_CUE_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + "__"
        let joined = values.joined(separator: "\n" + marker + "\n")
        let result = try await translate(joined)
        let parts = result.components(separatedBy: marker).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if parts.count == values.count, parts.allSatisfy({ !$0.isEmpty }) { return parts }
        // Never attach misaligned translations if the service changes a delimiter.
        if values.count == 1 { throw AetherSubtitleError.translationFailed }
        var fallback: [String] = []
        for value in values { try Task.checkCancellation(); fallback.append(try await translate(value)) }
        return fallback
    }

    private func translate(_ text: String) async throws -> String {
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        components.queryItems = ["client": "gtx", "dt": "t", "dj": "1", "ie": "UTF-8", "oe": "UTF-8", "sl": "auto", "tl": "vi", "q": text]
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let data = try await download(request, maximum: 1024 * 1024)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sentences = object["sentences"] as? [[String: Any]], !sentences.isEmpty else { throw AetherSubtitleError.translationFailed }
            let result = sentences.compactMap { $0["trans"] as? String }.joined()
            guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AetherSubtitleError.translationFailed }
            return result
        } catch {
            try Task.checkCancellation()
            throw AetherSubtitleError.translationFailed
        }
    }

    private func download(_ request: URLRequest, maximum: Int = maximumBytes) async throws -> Data {
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, let final = http.url, Self.validRemote(final),
              (200..<300).contains(http.statusCode) else { throw AetherSubtitleError.unavailable }
        guard data.count <= maximum, response.expectedContentLength <= Int64(maximum) else { throw AetherSubtitleError.tooLarge }
        return data
    }

    static func validRemote(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        return host != "localhost" && !host.hasSuffix(".localhost") && !host.hasSuffix(".local") &&
            host != "::1" && !host.hasPrefix("127.") && !host.hasPrefix("10.") && !host.hasPrefix("192.168.") && !host.hasPrefix("169.254.")
    }

    static func languageCode(_ value: String) -> String {
        let text = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[0-9]+$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let codes = ["vietnamese": "vi", "tiếng việt": "vi", "vietsub": "vi", "vie": "vi", "english": "en", "eng": "en",
                     "japanese": "ja", "jpn": "ja", "korean": "ko", "chinese": "zh", "french": "fr", "spanish": "es",
                     "german": "de", "italian": "it", "portuguese": "pt", "russian": "ru", "thai": "th", "indonesian": "id"]
        if let code = codes[text] { return code }
        if let pair = codes.first(where: { text.hasPrefix($0.key + " ") || text.hasPrefix($0.key + "(") || text.hasPrefix($0.key + " ·") }) { return pair.value }
        let first = text.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " }).first.map(String.init) ?? text
        if first.range(of: "^[a-z]{2}$", options: .regularExpression) != nil { return first }
        return "und"
    }

    static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(hash, radix: 16)
    }

    struct Cue {
        let start: Int
        let end: Int
        let text: String
    }
    private static func normalizedLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
    }
    static func cues(_ text: String) -> [Cue] {
        let lines = normalizedLines(text)
        var result: [Cue] = [], index = 0
        let timing = #"^\s*(?:[0-9]{1,3}:)?[0-9]{2}:[0-9]{2}[.,][0-9]{3}\s+-->\s+(?:[0-9]{1,3}:)?[0-9]{2}:[0-9]{2}[.,][0-9]{3}(?:\s.*)?$"#
        while index < lines.count {
            guard lines[index].range(of: timing, options: .regularExpression) != nil else { index += 1; continue }
            let start = index + 1
            var end = start
            while end < lines.count, !lines[end].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { end += 1 }
            if start < end {
                let text = lines[start..<end].joined(separator: "\n").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                if !text.isEmpty { result.append(Cue(start: start, end: end, text: text)) }
            }
            index = max(index + 1, end)
        }
        return result
    }
}

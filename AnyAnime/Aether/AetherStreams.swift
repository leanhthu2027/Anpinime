import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct AetherStreamServer: Identifiable, Equatable {
    let id: String
    let name: String
}
struct AetherMediaVariant: Identifiable, Equatable {
    let id: String
    let label: String
    let url: URL
    let headers: [String: String]
}
struct AetherStreamCaption: Identifiable, Equatable {
    let id: String
    let title: String
    let language: String
    let url: URL
    let format: String
    let headers: [String: String]
}
struct AetherStream: Equatable {
    let serverID: String
    let variants: [AetherMediaVariant]
    let captions: [AetherStreamCaption]
}
enum AetherStreamError: LocalizedError {
    case invalidMedia, unsupportedServer, rejected(Int), invalidResponse, noStreams
    var errorDescription: String? {
        switch self {
        case .invalidMedia: return "Thông tin phim hoặc tập không hợp lệ."
        case .unsupportedServer: return "Máy chủ Aether này chưa được hỗ trợ."
        case .rejected(let code): return "Máy chủ Aether trả lỗi HTTP \(code). Hãy thử lại sau."
        case .invalidResponse: return "Dữ liệu video Aether không hợp lệ."
        case .noStreams: return "Máy chủ chưa cung cấp video cho phim hoặc tập này."
        }
    }
}

/// Native transport for the KingLink source shipped in Aether's live provider
/// library. No browser, page playback, embedded controls, or HTML media capture.
/// Contract verified against aether.st's vendor-BbJGwvp8.js on 2026-11-11.
struct AetherStreamClient {
    static let servers = [
        AetherStreamServer(id: "lul", name: "Lul 👾"),
        AetherStreamServer(id: "nebula", name: "Nebula 🌌"),
        AetherStreamServer(id: "lil", name: "Lil 🐣"),
        AetherStreamServer(id: "ly", name: "Ly 🌸"),
        AetherStreamServer(id: "meridian", name: "Meridian 🪐"),
        AetherStreamServer(id: "rock", name: "Rock 🪨"),
        AetherStreamServer(id: "polaris", name: "Polaris 🌟"),
        AetherStreamServer(id: "aurora", name: "Aurora 💫"),
        AetherStreamServer(id: "tiki", name: "Tiki 🗿"),
        AetherStreamServer(id: "link", name: "Link 🔗"),
        AetherStreamServer(id: "vidfast", name: "Fast (4K) ⚡"),
        AetherStreamServer(id: "vidy", name: "Vidy 📺"),
        AetherStreamServer(id: "aether-subtitulado", name: "Subtitulado 🇪🇸"),
        AetherStreamServer(id: "aether-latino", name: "Latino 🇪🇸"),
        AetherStreamServer(id: "aether-castellano", name: "Castellano 🇪🇸"),
        AetherStreamServer(id: "vine", name: "Vine 🇩🇪"),
        AetherStreamServer(id: "gallic", name: "Gallic 🇫🇷"),
        AetherStreamServer(id: "baguette", name: "Baguette 🇫🇷"),
        AetherStreamServer(id: "poyraz", name: "Poyraz 🇹🇷"),
        AetherStreamServer(id: "yildiz", name: "Yıldız 🇹🇷"),
        AetherStreamServer(id: "vidlink", name: "KingLink 🔥"),
        AetherStreamServer(id: "animetsu", name: "Animetsu 🏯")
    ]
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)
    let transport: Transport
    let metadataCredential: () -> String?
    private let now: () -> Date
    init(transport: Transport? = nil, metadataCredential: @escaping () -> String? = AetherMetadataSettings.credential, now: @escaping () -> Date = Date.init) {
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw AetherStreamError.invalidResponse }
            return (data, response)
        }
        self.now = now
        self.metadataCredential = metadataCredential
    }
    func resolve(mediaType: String, id: Int, season: Int?, episode: Int?, serverID: String? = nil, excluding: Set<String> = []) async throws -> AetherStream {
        if serverID == nil {
            let candidates = Self.servers.filter { Self.supports($0.id, mediaType:mediaType) && !excluding.contains($0.id) }
            var last: Error = AetherStreamError.noStreams
            // Aether's runAll walks sources by descending scraper rank and
            // selects the first successful source; don't race lower-ranked ones.
            for source in candidates {
                try Task.checkCancellation()
                do { return try await resolve(mediaType:mediaType,id:id,season:season,episode:episode,serverID:source.id) }
                catch { try Task.checkCancellation(); last = error }
            }
            throw last
        }
        let server = serverID ?? "vidlink"
        guard Self.servers.contains(where: { $0.id == server }) else { throw AetherStreamError.unsupportedServer }
        if server != "vidlink" {
            return try await resolveAdditional(server, mediaType: mediaType, id: id, season: season, episode: episode)
        }
        let url = try Self.requestURL(mediaType: mediaType, id: id, season: season, episode: episode, now: now())
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://vidlink.pro/", forHTTPHeaderField: "Referer")
        request.setValue("https://vidlink.pro", forHTTPHeaderField: "Origin")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        guard response.statusCode == 200 else { throw AetherStreamError.rejected(response.statusCode) }
        guard data.count <= 4 * 1024 * 1024 else { throw AetherStreamError.invalidResponse }
        return try Self.decode(data, serverID: server)
    }
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    static func requestURL(mediaType: String, id: Int, season: Int?, episode: Int?, now: Date) throws -> URL {
        guard id > 0, mediaType == "movie" || mediaType == "tv" else { throw AetherStreamError.invalidMedia }
        var path = "https://vidlink.pro/api/b/\(mediaType)/\(AetherProviderToken.make(id: String(id), now: now))"
        if mediaType == "tv" {
            guard let season, let episode, season >= 0, episode > 0 else { throw AetherStreamError.invalidMedia }
            path += "/\(season)/\(episode)"
        }
        guard let url = URL(string: path + "?multiLang=0") else { throw AetherStreamError.invalidMedia }
        return url
    }
    static func safeURL(_ value: String?) -> URL? {
        guard let value, value.count < 24_000, let url = URL(string: value),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else { return nil }
        return url
    }
    static func cleanHeaders(_ value: Any?) -> [String: String] {
        guard let headers = value as? [String: String] else { return [:] }
        let canonical = ["referer": "Referer", "origin": "Origin", "user-agent": "User-Agent",
                         "accept": "Accept", "authorization": "Authorization", "cookie": "Cookie"]
        var result: [String: String] = [:]
        for (key, value) in headers {
            guard let name = canonical[key.lowercased()], !value.contains("\r"), !value.contains("\n"), value.count < 16_384 else { continue }
            result[name] = value
        }
        return result
    }
    static func decode(_ data: Data, serverID: String = "vidlink") throws -> AetherStream {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let stream = root["stream"] as? [String: Any] else { throw AetherStreamError.invalidResponse }
        var headers = cleanHeaders(stream["preferredHeaders"])
        headers.merge(cleanHeaders(stream["headers"])) { _, value in value }
        var variants: [AetherMediaVariant] = []
        if stream["type"] as? String == "file", let qualities = stream["qualities"] as? [String: [String: Any]] {
            for (quality, entry) in qualities {
                guard entry["type"] as? String == "mp4", let url = safeURL(entry["url"] as? String) else { continue }
                var variantHeaders = headers
                variantHeaders.merge(cleanHeaders(entry["headers"])) { _, value in value }
                let label = quality == "4k" ? "4K" : (quality == "unknown" ? "Mặc định" : "\(quality)p")
                variants.append(AetherMediaVariant(id: quality, label: label, url: url, headers: variantHeaders))
            }
            variants.sort { qualityRank($0.id) > qualityRank($1.id) }
        } else if stream["type"] as? String == "hls", let url = safeURL((stream["playlist"] ?? stream["url"]) as? String) {
            variants = [AetherMediaVariant(id: "auto", label: "Tự động", url: url, headers: headers)]
        }
        guard !variants.isEmpty else { throw AetherStreamError.noStreams }
        let captions = (stream["captions"] as? [[String: Any]] ?? []).compactMap { entry -> AetherStreamCaption? in
            guard let url = safeURL(entry["url"] as? String) else { return nil }
            let raw = entry["language"] as? String ?? "und"
            let language = captionLanguage(raw)
            let format = (entry["type"] as? String ?? "srt").lowercased()
            guard ["srt", "vtt", "ass", "ssa"].contains(format) else { return nil }
            let id = (entry["id"] as? String) ?? (entry["id"] as? NSNumber)?.stringValue ?? url.absoluteString
            return AetherStreamCaption(id: id, title: entry["display"] as? String ?? raw,
                                       language: language, url: url, format: format,
                                       headers: cleanHeaders(entry["headers"]))
        }
        var seen = Set<String>()
        return AetherStream(serverID: serverID, variants: variants, captions: captions.filter { seen.insert($0.url.absoluteString).inserted })
    }
    /// Response fields and media headers reproduced from Aether's Ly scraper.
    static func decodeLy(_ data: Data) throws -> AetherStream {
        try decodeAdditional((try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:], server:"ly", headers:contracts["ly"]!.headers)
    }
    private static func qualityRank(_ value: String) -> Int { value == "4k" ? 2160 : (Int(value) ?? 0) }
    static func captionLanguage(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let aliases = ["english": "en", "vietnamese": "vi", "tiếng việt": "vi", "français": "fr", "french": "fr",
                       "deutsch": "de", "german": "de", "español": "es", "spanish": "es", "português": "pt",
                       "русский": "ru", "中文": "zh", "日本語": "ja", "한국어": "ko", "indonesian": "id", "filipino": "tl"]
        return aliases[normalized] ?? normalized
    }
}

/// XSalsa20-Poly1305 request envelope used by Aether's bundled KingLink scraper.
/// The key and all-zero nonce are the upstream public provider protocol, not an
/// app credential. Reproduce it exactly; metadata credentials never enter here.
enum AetherProviderToken {
    private static let key: [UInt8] = [199,81,54,197,102,139,191,230,90,126,202,212,49,167,69,219,104,181,243,129,85,91,56,216,246,198,153,68,156,241,31,205]
    static func make(id: String, now: Date) -> String {
        var message = Array(id.utf8)
        let expiry = UInt64(max(0, floor(now.timeIntervalSince1970))) + 43_200
        message += (0..<8).reversed().map { UInt8(truncatingIfNeeded: expiry >> ($0 * 8)) }
        let subkey = hsalsa(key)
        let stream = salsaStream(key: subkey, count: message.count + 32)
        let cipher = message.enumerated().map { $0.element ^ stream[$0.offset + 32] }
        let tag = poly1305(cipher, key: Array(stream.prefix(32)))
        return Data([UInt8](repeating: 0, count: 24) + tag + cipher).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func load(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset+1]) << 8 | UInt32(bytes[offset+2]) << 16 | UInt32(bytes[offset+3]) << 24
    }
    private static func bytes(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    private static func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32-n)) }
    private static func state(_ key: [UInt8]) -> [UInt32] {
        var s = [UInt32](repeating: 0, count: 16)
        s[0] = 0x61707865; s[5] = 0x3320646e; s[10] = 0x79622d32; s[15] = 0x6b206574
        for i in 0..<4 { s[1+i] = load(key, i*4); s[11+i] = load(key, 16+i*4) }
        return s
    }
    private static func rounds(_ input: [UInt32]) -> [UInt32] {
        var x = input
        func quarter(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            x[b] ^= rotate(x[a] &+ x[d],7); x[c] ^= rotate(x[b] &+ x[a],9)
            x[d] ^= rotate(x[c] &+ x[b],13); x[a] ^= rotate(x[d] &+ x[c],18)
        }
        for _ in 0..<10 {
            quarter(0,4,8,12); quarter(5,9,13,1); quarter(10,14,2,6); quarter(15,3,7,11)
            quarter(0,1,2,3); quarter(5,6,7,4); quarter(10,11,8,9); quarter(15,12,13,14)
        }
        return x
    }
    private static func hsalsa(_ key: [UInt8]) -> [UInt8] {
        let x = rounds(state(key))
        return [0,5,10,15,6,7,8,9].flatMap { bytes(x[$0]) }
    }
    private static func salsaStream(key: [UInt8], count: Int) -> [UInt8] {
        var input = state(key), result: [UInt8] = []
        while result.count < count {
            let x = rounds(input)
            result += (0..<16).flatMap { bytes(x[$0] &+ input[$0]) }
            input[8] &+= 1
            if input[8] == 0 { input[9] &+= 1 }
        }
        return Array(result.prefix(count))
    }
    private static func poly1305(_ message: [UInt8], key: [UInt8]) -> [UInt8] {
        func word(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(load(b,i)) }
        let mask: UInt64 = 0x3ffffff
        let r = [word(key,0)&mask,(word(key,3)>>2)&0x3ffff03,(word(key,6)>>4)&0x3ffc0ff,
                 (word(key,9)>>6)&0x3f03fff,(word(key,12)>>8)&0xfffff]
        var h = [UInt64](repeating: 0, count: 5)
        var offset = 0
        while offset < message.count {
            let length = min(16, message.count-offset)
            var b = [UInt8](repeating: 0, count: 17)
            b.replaceSubrange(0..<length, with: message[offset..<offset+length]); b[length] = 1
            h[0] += word(b,0)&mask; h[1] += (word(b,3)>>2)&mask; h[2] += (word(b,6)>>4)&mask
            h[3] += (word(b,9)>>6)&mask; h[4] += (word(b,12)>>8) | (UInt64(b[16])<<24)
            var d = [UInt64](repeating: 0, count: 5)
            for i in 0..<5 { for j in 0..<5 {
                let k = (i-j+5)%5
                d[i] += h[j] * r[k] * (j > i ? 5 : 1)
            } }
            for i in 0..<4 { d[i+1] += d[i] >> 26; h[i] = d[i]&mask }
            h[4] = d[4]&mask; h[0] += (d[4]>>26)*5
            h[1] += h[0]>>26; h[0] &= mask
            offset += length
        }
        for i in 1..<4 { h[i+1] += h[i]>>26; h[i] &= mask }
        h[0] += (h[4]>>26)*5; h[4] &= mask; h[1] += h[0]>>26; h[0] &= mask
        var g = h; g[0] += 5
        for i in 0..<4 { g[i+1] += g[i]>>26; g[i] &= mask }
        g[4] = g[4] &- (1<<26)
        let choose = (g[4]>>63) &- 1
        for i in 0..<5 { h[i] = (h[i] & ~choose) | (g[i] & choose) }
        let packed = [(h[0] | h[1]<<26)&0xffffffff,(h[1]>>6 | h[2]<<20)&0xffffffff,
                      (h[2]>>12 | h[3]<<14)&0xffffffff,(h[3]>>18 | h[4]<<8)&0xffffffff]
        var carry: UInt64 = 0, output: [UInt8] = []
        for i in 0..<4 { let value = packed[i] + word(key,16+i*4) + carry
            output += bytes(UInt32(truncatingIfNeeded: value)); carry = value>>32 }
        return output
    }
}

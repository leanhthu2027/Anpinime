import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

@MainActor
final class MovieProvider: MovieSourceProviding {
    let source: ContentSource
    private(set) var baseURL: URL
    private var publicCategories: [AnimeCategory] = []
    var categories: [AnimeCategory] { publicCategories }
    var notice: String { "" }
    private var format: MovieAPIFormat
    private let session: URLSession
    private var ticket: String?
    private var ticketExpiry = Date.distantPast
    private var cachedJSON: [URL: (Date, MovieCatalog.Object)] = [:]

    init(source: ContentSource, session suppliedSession: URLSession? = nil) {
        precondition(source == .film4k || source == .kkphim)
        self.source = source
        format = source == .film4k ? .free2 : .free1
        baseURL = source == .kkphim ? URL(string: "https://phimapi.com")! : format.defaultURL
        #if DEBUG
        if PlaybackSmokeTest.providerFixture { baseURL = URL(string: "http://127.0.0.1:8765")! }
        #endif
        publicCategories = MovieBrowseCatalog.defaults(for: source)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.httpCookieStorage = .shared
        config.httpShouldSetCookies = true
        session = suppliedSession ?? URLSession(configuration: config)
    }

    func invalidate() {
        cachedJSON.removeAll()
    }

    func home(onInitial: ([AnimeSection]) -> Void = { _ in }) async throws -> [AnimeSection] {
        #if DEBUG
        // Keep the historical ticket/relay fixture independent of the production source.
        if source == .film4k, PlaybackSmokeTest.providerFixture {
            return MovieCatalog.filmSections(try await request(MovieCatalog.route("api/home", base: baseURL)), base: baseURL)
        }
        #endif
        // Return the first useful page immediately; other categories load on demand.
        let items = try await list(path: "")
        guard !items.isEmpty else { throw MovieSourceError.invalidData }
        let initial = [AnimeSection(title: "Mới cập nhật", items: items, categoryPath: format.listPath)]
        onInitial(initial)
        #if DEBUG
        if PlaybackSmokeTest.providerFixture { return initial }
        #endif
        async let updatedCategories = loadBrowseCategories()
        let configs = Array(format.homeSectionsConfig.dropFirst())
        var extra: [Int: AnimeSection] = [:]
        await withTaskGroup(of: (Int, AnimeSection?).self) { group in
            for (index, config) in configs.enumerated() {
                group.addTask { [weak self] in
                    guard let self, !Task.isCancelled,
                          let rows = try? await self.list(path: config.path), !rows.isEmpty else { return (index, nil) }
                    return (index, AnimeSection(title: config.title, items: rows, categoryPath: config.path))
                }
            }
            for await (index, section) in group {
                if let section { extra[index] = section }
            }
        }
        try Task.checkCancellation()
        publicCategories = await updatedCategories
        return initial + extra.keys.sorted().compactMap { extra[$0] }
    }

    func list(path: String, page: Int = 1) async throws -> [Anime] {
        if source == .kkphim, MovieBrowseCatalog.kkWebsiteLists.contains(path) {
            let url = MovieCatalog.route(String(path.dropFirst(5)), base: URL(string: "https://kkphim.com")!, query: [.init(name: "page", value: String(page))])
            return MovieBrowseCatalog.kkWebsiteItems(try await websiteHTML(url))
        }
        let target = path.isEmpty || path == "latest" ? format.listPath : path
        guard MovieCatalog.isCatalogPath(target, format: format) else { throw MovieSourceError.invalidData }
        let json = try await catalogRequest(MovieCatalog.route(target, base: baseURL, query: [.init(name: "page", value: String(page))]))
        return MovieCatalog.legacyItems(json, base: baseURL, format: format, source: source)
    }

    func search(_ query: String) async throws -> [Anime] {
        let json = try await catalogRequest(MovieCatalog.route(format.searchPath, base: baseURL, query: [.init(name: "keyword", value: query)]))
        return MovieCatalog.legacyItems(json, base: baseURL, format: format, source: source)
    }

    func detail(_ anime: Anime) async throws -> AnimeDetail {
        guard anime.source == source else { throw MovieSourceError.invalidData }
        #if DEBUG
        if source == .film4k, PlaybackSmokeTest.providerFixture {
            return try MovieCatalog.filmDetail(try await request(MovieCatalog.route("api/title/" + anime.url.lastPathComponent, base: baseURL)), anime: anime, base: baseURL)
        }
        #endif
        let json = try await catalogRequest(anime.url)
        return try MovieCatalog.legacyDetail(json, anime: anime)
    }

    private func loadBrowseCategories() async -> [AnimeCategory] {
        let fallback = MovieBrowseCatalog.defaults(for: source)
        if source == .film4k {
            guard let html = try? await websiteHTML(URL(string: "https://phim.nguonc.com/api-document")!) else { return fallback }
            let parsed = MovieBrowseCatalog.nguoncMenu(html)
            guard parsed.contains(where: { $0.group == "Thể loại" }) else { return fallback }
            return fallback.filter { $0.path == format.listPath } + parsed + fallback.filter { $0.group == "Ngôn ngữ" }
        }
        guard source == .kkphim else { return fallback }
        var result = fallback.filter { $0.group == "Danh sách phim" }
        for (endpoint, group) in [("the-loai", "Thể loại"), ("quoc-gia", "Quốc gia")] {
            if let json = try? await catalogRequest(MovieCatalog.route(endpoint, base: baseURL)) {
                let items = MovieBrowseCatalog.kkTaxonomy(json, group: group, path: "v1/api/" + endpoint + "/")
                result += items.isEmpty ? fallback.filter { $0.group == group } : items
            } else { result += fallback.filter { $0.group == group } }
        }
        return result
    }

    private func websiteHTML(_ url: URL) async throws -> String {
        let expected = source == .kkphim ? "kkphim.com" : "phim.nguonc.com"
        guard url.host == expected, url.scheme == "https" else { throw MovieSourceError.invalidData }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue(AnimeService.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else { throw MovieSourceError.invalidData }
        return html
    }

    private func catalogRequest(_ url: URL) async throws -> MovieCatalog.Object {
        if let (date, json) = cachedJSON[url], Date().timeIntervalSince(date) < 120 { return json }
        let json = try await request(url)
        if cachedJSON.count >= 80 { cachedJSON.removeAll() }
        cachedJSON[url] = (Date(), json)
        return json
    }

    func resolve(_ episode: Episode, refresh: Bool = false) async throws -> ResolvedPlayback {
        guard episode.source == source else { throw MovieSourceError.invalidData }
        switch episode.playback {
        case .aether:
            throw MovieSourceError.invalidData
        case .film4k(let slug, let season, let number, let server):
            async let watch = request(MovieCatalog.route("api/watch/" + slug, base: baseURL))
            try await refreshTicket(force: refresh)
            let json = try await watch
            let sources = MovieCatalog.filmStreams(json, season: season, episode: number)
            guard !sources.isEmpty else { throw MovieSourceError.noVideo }
            // Prefer a native HLS/MP4 source; opaque embeds and DASH use their original web player.
            let candidates = sources.sorted { Self.isNative($0) && !Self.isNative($1) }
            let selected = candidates[min(server, candidates.count - 1)]
            guard let url = MovieCatalog.url(selected["url"], base: baseURL) else { throw MovieSourceError.noVideo }
            var headers = ["Referer": episode.url.absoluteString, "User-Agent": AnimeService.userAgent]
            if url.host == baseURL.host, let ticket { headers["X-F4K-PT"] = ticket }
            let native = Self.isNative(selected)
            return ResolvedPlayback(url: native ? url : episode.url, headers: headers, webURL: episode.url, isWeb: !native)
        case .catalogEpisode(let detailURL, let serverName, let episodeKey):
            // Refresh the exact provider, server and episode, even if the API reorders rows.
            let activeDetailURL = detailURL
            let json = try await request(detailURL)
            guard let row = MovieCatalog.episodeRow(json, serverName: serverName, key: episodeKey),
                  let stream = MovieCatalog.legacyStream(row, base: activeDetailURL) else { throw MovieSourceError.noVideo }
            let web = MovieCatalog.url(row["link_embed"] ?? row["embed"], base: activeDetailURL)
            let originHost = activeDetailURL.scheme.flatMap { s in activeDetailURL.host.map { "\(s)://\($0)" } } ?? baseURL.absoluteString
            if source == .film4k, stream.web, Self.isStreamCEmbed(stream.url),
               let native = await resolveStreamC(embedURL: stream.url, refererOrigin: originHost) {
                return native
            }
            return ResolvedPlayback(url: stream.url, headers: ["Referer": originHost + "/", "Origin": originHost, "User-Agent": AnimeService.userAgent],
                                    webURL: stream.web ? web : nil, isWeb: stream.web)
        case .directStream(let url, let webURL, let isWeb, let referer):
            let refURL = referer ?? baseURL
            let originHost = refURL.scheme.flatMap { s in refURL.host.map { "\(s)://\($0)" } } ?? baseURL.absoluteString
            if source == .film4k, isWeb, Self.isStreamCEmbed(url),
               let native = await resolveStreamC(embedURL: url, refererOrigin: originHost) {
                return native
            }
            return ResolvedPlayback(url: url, headers: ["Referer": originHost + "/", "Origin": originHost, "User-Agent": AnimeService.userAgent],
                                    webURL: webURL, isWeb: isWeb)
        case .animePage:
            throw MovieSourceError.noVideo
        }
    }

    private static func isNative(_ source: MovieCatalog.Object) -> Bool {
        guard source["drm"] == nil, let url = URL(string: MovieCatalog.text(source["url"])) else { return false }
        return ["m3u8", "mp4", "m4v", "mov"].contains(url.pathExtension.lowercased())
    }

    static func isStreamCEmbed(_ url: URL) -> Bool {
        let lower = url.absoluteString.lowercased()
        if lower.contains("streamc.xyz") { return true }
        if lower.contains("/embed.php"), (lower.contains("?hash=") || lower.contains("&hash=")) { return true }
        return false
    }

    private func resolveStreamC(embedURL: URL, refererOrigin: String) async -> ResolvedPlayback? {
        #if canImport(CryptoKit)
        var pageReq = URLRequest(url: embedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        pageReq.setValue(AnimeService.userAgent, forHTTPHeaderField: "User-Agent")
        pageReq.setValue(refererOrigin.hasSuffix("/") ? refererOrigin : refererOrigin + "/", forHTTPHeaderField: "Referer")
        pageReq.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        guard let (htmlData, htmlResp) = try? await session.data(for: pageReq),
              let htmlHTTP = htmlResp as? HTTPURLResponse, (200..<300).contains(htmlHTTP.statusCode),
              let html = String(data: htmlData, encoding: .utf8), !html.isEmpty else { return nil }

        let finalEmbed = htmlHTTP.url ?? embedURL
        let embedOrigin: String = {
            let scheme = finalEmbed.scheme ?? "https"
            let host = finalEmbed.host ?? "embed1.streamc.xyz"
            let port = finalEmbed.port.map { ":\($0)" } ?? ""
            return "\(scheme)://\(host)\(port)"
        }()

        // Parse <script id="stream-bootstrap">{...}</script>
        var rawAPI = finalEmbed.absoluteString
        if let regex = try? NSRegularExpression(pattern: #"<script[^>]*id=["']stream-bootstrap["'][^>]*>(.*?)</script>"#,
                                                options: [.caseInsensitive, .dotMatchesLineSeparators]),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            let body = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let cfgData = body.data(using: .utf8),
               let cfg = try? JSONSerialization.jsonObject(with: cfgData) as? [String: Any],
               let api = (cfg["api"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !api.isEmpty {
                rawAPI = api
            }
        }
        guard let apiURL = URL(string: rawAPI, relativeTo: finalEmbed)?.absoluteURL else { return nil }
        let frameOrigin = refererOrigin.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let frameRef = frameOrigin + "/"

        var streamHeaders: [String: String] = [
            "Origin": embedOrigin,
            "Referer": embedOrigin + "/",
            "User-Agent": AnimeService.userAgent
        ]
        if let hash = URLComponents(url: finalEmbed, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "hash" })?.value,
           !hash.isEmpty {
            streamHeaders["X-StreamC-Hash"] = hash
        }

        let bootstrapBody: [String: Any] = [
            "action": "bootstrap",
            "referrer": frameRef,
            "frame_origins": [frameOrigin],
            "request_grant": true,
            "playlist_format": "hls",
            "pretty_url": true,
            "path_chunks": true,
            "bootstrap_format": "json"
        ]
        guard let bootResp = await postStreamCJSON(apiURL: apiURL, body: bootstrapBody, origin: embedOrigin, referer: finalEmbed.absoluteString) else { return nil }

        // Fast-path: StreamC r25+ returns preissued.playlist directly in bootstrap response
        if (bootResp["turnstileEnabled"] as? Bool) != true,
           let preissued = bootResp["preissued"] as? [String: Any],
           let rawPre = (preissued["playlist"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawPre.isEmpty, rawPre != "null",
           let playlistURL = URL(string: rawPre, relativeTo: apiURL)?.absoluteURL {
            return ResolvedPlayback(url: playlistURL, headers: streamHeaders, webURL: finalEmbed, isWeb: false)
        }

        // Standard path: decrypt bootstrapEnvelope or use direct bootstrap token, then POST action=issue
        let bootstrapToken: Any? = {
            if let obj = bootResp["bootstrap"] as? [String: Any] { return obj }
            if let str = (bootResp["bootstrap"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !str.isEmpty, str != "null" { return str }
            if let env = bootResp["bootstrapEnvelope"] as? [String: Any] {
                return Self.decryptStreamCBootstrapEnvelope(env, apiURL: apiURL.absoluteString)
            }
            return nil
        }()
        guard let bootstrapToken else { return nil }

        let issueBody: [String: Any] = [
            "action": "issue",
            "bootstrap": bootstrapToken,
            "turnstile_response": NSNull(),
            "playlist_format": "hls",
            "pretty_url": true,
            "path_chunks": true,
            "frame_origins": [frameOrigin]
        ]
        guard let issueResp = await postStreamCJSON(apiURL: apiURL, body: issueBody, origin: embedOrigin, referer: finalEmbed.absoluteString),
              (issueResp["turnstileRequired"] as? Bool) != true,
              let rawPlaylist = (issueResp["playlist"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPlaylist.isEmpty, rawPlaylist != "null",
              let playlistURL = URL(string: rawPlaylist, relativeTo: apiURL)?.absoluteURL else { return nil }

        return ResolvedPlayback(url: playlistURL, headers: streamHeaders, webURL: finalEmbed, isWeb: false)
        #else
        return nil
        #endif
    }

    #if canImport(CryptoKit)
    private func postStreamCJSON(apiURL: URL, body: [String: Any], origin: String, referer: String) async -> [String: Any]? {
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.httpBody = payload
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(AnimeService.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(origin, forHTTPHeaderField: "Origin")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    private static func decryptStreamCBootstrapEnvelope(_ env: [String: Any], apiURL: String) -> [String: Any]? {
        guard let ivB64 = env["iv"] as? String,
              let ctB64 = env["ciphertext"] as? String,
              let tagB64 = env["tag"] as? String,
              let iv = Data(base64Encoded: ivB64),
              let ciphertext = Data(base64Encoded: ctB64),
              let tag = Data(base64Encoded: tagB64) else { return nil }
        let keyDigest = SHA256.hash(data: Data("stream-bootstrap-v1\n\(apiURL)".utf8))
        let key = SymmetricKey(data: Data(keyDigest))
        guard let nonce = try? AES.GCM.Nonce(data: iv),
              let sealed = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag),
              let plain = try? AES.GCM.open(sealed, using: key, authenticating: Data(apiURL.utf8)),
              let json = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else { return nil }
        return json
    }
    #endif

    private func refreshTicket(force: Bool) async throws {
        if !force, ticketExpiry > Date().addingTimeInterval(60) { return }
        let json = try await request(MovieCatalog.route("api/play-ticket", base: baseURL), method: "POST")
        ticket = (json["token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let milliseconds = json["expires"] as? Double {
            ticketExpiry = Date(timeIntervalSince1970: milliseconds / 1000)
        } else if json["ok"] as? Bool == true {
            ticketExpiry = Date().addingTimeInterval(120)
        } else { throw MovieSourceError.invalidData }
    }

    private func request(_ url: URL, method: String = "GET") async throws -> MovieCatalog.Object {
        guard url.host == baseURL.host, url.scheme == baseURL.scheme else {
            throw MovieSourceError.unavailable("Đường dẫn không thuộc " + source.title + ".")
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(AnimeService.userAgent, forHTTPHeaderField: "User-Agent")
        var originComponents = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        originComponents.path = ""; originComponents.query = nil; originComponents.fragment = nil
        let origin = originComponents.string ?? baseURL.absoluteString
        req.setValue(origin, forHTTPHeaderField: "Origin")
        req.setValue(origin + "/", forHTTPHeaderField: "Referer")
        let maxAttempts = (url.host == "127.0.0.1" || url.host == "localhost") ? 1 : 2
        var lastError: Error = MovieSourceError.invalidData
        for attempt in 1...maxAttempts {
            do {
                let (data, response) = try await session.data(for: req)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw MovieSourceError.invalidData }
                guard (200..<300).contains(http.statusCode) else { throw MovieSourceError.http(http.statusCode) }
                return try MovieCatalog.object(data)
            } catch {
                try Task.checkCancellation()
                lastError = error
                if case MovieSourceError.http(let status) = error, status != 429, !(500...599).contains(status) { throw error }
                if attempt < maxAttempts {
                    try await Task.sleep(nanoseconds: 180_000_000)
                }
            }
        }
        throw lastError
    }
}

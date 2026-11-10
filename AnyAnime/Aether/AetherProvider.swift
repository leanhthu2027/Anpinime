import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Native Anpinime catalog backed by the documented TMDB API, as in Streambert.
/// Aether remains the video/subtitle backend; metadata credentials never reach it.
@MainActor
final class AetherProvider: MovieSourceProviding {
    let baseURL = AetherDomainPolicy.defaultURL
    private(set) var categories: [AnimeCategory] = AetherCatalog.listRows.map { .init(title: $0.title, path: $0.path, group: "Danh sách phim") }
    let notice = ""
    private let session: URLSession
    private let credential: () -> String?
    private let language: () -> String
    private let resolveDomain: (_ force: Bool) async throws -> URL
    private var credentialIdentity: String?
    private var languageIdentity = ""
    private var cacheGeneration = UUID()
    private var jsonCache: [String: (date: Date, object: AetherCatalog.Object)] = [:]
    private var detailCache: [String: (date: Date, detail: AnimeDetail)] = [:]

    init(session: URLSession? = nil, credential: @escaping () -> String? = AetherMetadataSettings.credential,
         language: @escaping () -> String = { UserDefaults.standard.string(forKey: AetherMetadataSettings.languageKey) ?? "vi-VN" },
         resolveDomain: @escaping (_ force: Bool) async throws -> URL = { try await AetherDomainResolver.shared.resolve(force: $0).origin }) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 20
        config.httpShouldSetCookies = false
        self.session = session ?? URLSession(configuration: config)
        self.credential = credential; self.language = language; self.resolveDomain = resolveDomain
    }
    func invalidate() {
        cacheGeneration = UUID()
        jsonCache.removeAll(); detailCache.removeAll()
    }

    func home(onInitial: ([AnimeSection]) -> Void = { _ in }) async throws -> [AnimeSection] {
        _ = try authorization()
        let generation = cacheGeneration
        let trending = try await list(path: "tmdb/trending")
        var sections = trending.isEmpty ? [] : [AnimeSection(title: "Thịnh hành", items: trending, categoryPath: "tmdb/trending")]
        if !sections.isEmpty { onInitial(sections) }
        // Four concurrent requests, never an unbounded burst for a home page.
        async let fresh = try? list(path: "tmdb/new")
        async let movies = try? list(path: "tmdb/movie")
        async let series = try? list(path: "tmdb/tv")
        async let genres: Void = loadGenres()
        for (title, path, result) in [("Phim mới", "tmdb/new", await fresh), ("Phim lẻ", "tmdb/movie", await movies), ("Phim bộ", "tmdb/tv", await series)] {
            if let result, !result.isEmpty { sections.append(.init(title: title, items: result, categoryPath: path)) }
        }
        await genres
        try Task.checkCancellation()
        guard cacheGeneration == generation else { throw CancellationError() }
        // Native Home keeps genre shelves as well as the full Browse taxonomy.
        // At most two discovery requests; an optional shelf cannot fail Home.
        async let movieGenre = genreSection(categories.first { $0.path.hasPrefix("tmdb/genre/movie/") }, prefix: "Phim lẻ")
        async let tvGenre = genreSection(categories.first { $0.path.hasPrefix("tmdb/genre/tv/") }, prefix: "Phim bộ")
        if let shelf = await movieGenre { sections.append(shelf) }
        if let shelf = await tvGenre { sections.append(shelf) }
        try Task.checkCancellation()
        guard cacheGeneration == generation else { throw CancellationError() }
        guard !sections.isEmpty else { throw AetherCatalogError.invalidData }
        return sections
    }
    private func genreSection(_ category: AnimeCategory?, prefix: String) async -> AnimeSection? {
        guard let category, let items = try? await list(path: category.path), !items.isEmpty else { return nil }
        return AnimeSection(title: "\(prefix) · \(category.title)", items: items, categoryPath: category.path)
    }
    func list(path: String, page: Int = 1) async throws -> [Anime] {
        guard (1...500).contains(page) else { throw AetherCatalogError.invalidRoute }
        let route = try AetherCatalog.listRoute(path)
        let json = try await request(route.path, query: route.query + [.init(name: "page", value: String(page))])
        return AetherCatalog.items(json, type: route.type)
    }
    func search(_ query: String) async throws -> [Anime] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let result = try await request("search/multi", query: [.init(name: "query", value: query), .init(name: "include_adult", value: "false"), .init(name: "page", value: "1")])
        return AetherCatalog.items(result)
    }
    func detail(_ anime: Anime) async throws -> AnimeDetail {
        guard anime.source == .aether, let identity = AetherCatalog.identity(anime.url) else { throw AetherCatalogError.invalidRoute }
        // Validate configuration even when a prior successful detail is cached.
        _ = try authorization()
        let generation = cacheGeneration
        if let cache = detailCache[anime.id], Date().timeIntervalSince(cache.date) < 300 { return cache.detail }
        let data = try await request("\(identity.type)/\(identity.id)")
        guard AetherCatalog.integer(data["id"]) == identity.id else { throw AetherCatalogError.invalidData }
        let episodes: [Episode]
        if identity.type == "movie" {
            episodes = [Episode(title: "Xem phim", url: AetherCatalog.canonical("movie", id: identity.id), number: 1, season: "Anpinime VIP",
                source: .aether, playback: .aether(mediaType: "movie", id: identity.id, season: nil, episode: nil))]
        } else {
            let raw = data["seasons"] as? [AetherCatalog.Object] ?? []
            var seen = Set<Int>()
            let seasons = raw.compactMap { row -> Int? in
                guard let number = AetherCatalog.integer(row["season_number"]), number >= 0,
                      let count = AetherCatalog.integer(row["episode_count"]), count > 0,
                      seen.insert(number).inserted else { return nil }
                return number
            }.sorted()
            guard seasons.count <= 1000 else { throw AetherCatalogError.invalidData }
            var loaded: [Int: [Episode]] = [:]
            // Bound network concurrency and preserve cancellation for very long series.
            // Any incomplete season fails explicitly instead of silently truncating TV.
            for start in stride(from: 0, to: seasons.count, by: 4) {
                try Task.checkCancellation()
                let batch = Array(seasons[start..<min(start + 4, seasons.count)])
                try await withThrowingTaskGroup(of: (Int, [Episode]).self) { group in
                    for number in batch { group.addTask { (number, try await self.season(id: identity.id, number: number)) } }
                    for try await (number, rows) in group { loaded[number] = rows }
                }
            }
            episodes = seasons.flatMap { loaded[$0] ?? [] }
        }
        try Task.checkCancellation()
        _ = try authorization()
        guard cacheGeneration == generation else { throw CancellationError() }
        let title = AetherCatalog.text(data[identity.type == "movie" ? "title" : "name"])
        let summary = AetherCatalog.text(data["overview"])
        let date = AetherCatalog.text(data[identity.type == "movie" ? "release_date" : "first_air_date"])
        let genres = (data["genres"] as? [AetherCatalog.Object] ?? []).map { AetherCatalog.text($0["name"]) }.filter { !$0.isEmpty }.joined(separator: ", ")
        let result = AnimeDetail(title: title.isEmpty ? anime.title : title,
            posterURL: AetherCatalog.image(data["poster_path"], size: "w500") ?? anime.imageURL,
            bannerURL: AetherCatalog.image(data["backdrop_path"], size: "w1280") ?? anime.bannerURL,
            summary: summary.isEmpty ? anime.summary : summary,
            info: [String(date.prefix(4)), genres, "Metadata: TMDB"].filter { !$0.isEmpty }.joined(separator: " • "), episodes: episodes)
        if detailCache.count >= 40 { detailCache.removeAll() }
        detailCache[anime.id] = (Date(), result)
        return result
    }
    private func season(id: Int, number: Int) async throws -> [Episode] {
        let data = try await request("tv/\(id)/season/\(number)")
        guard AetherCatalog.integer(data["season_number"]) == number,
              let rows = data["episodes"] as? [AetherCatalog.Object], rows.count <= 10000 else { throw AetherCatalogError.invalidData }
        var seen = Set<Int>()
        return try rows.compactMap { row in
            guard let episode = AetherCatalog.integer(row["episode_number"]), episode > 0,
                  AetherCatalog.integer(row["season_number"]) == number else { throw AetherCatalogError.invalidData }
            guard seen.insert(episode).inserted else { return nil }
            let url = AetherCatalog.canonical("tv", id: id).appendingPathComponent("season/\(number)/episode/\(episode)")
            return Episode(title: "Tập \(episode)", url: url, number: episode, season: number == 0 ? "Ngoại truyện" : "Phần \(number)",
                source: .aether, playback: .aether(mediaType: "tv", id: id, season: number, episode: episode))
        }.sorted { ($0.number ?? 0) < ($1.number ?? 0) }
    }
    func resolve(_ episode: Episode, refresh: Bool = false) async throws -> ResolvedPlayback {
        guard episode.source == .aether,
              case .aether(let kind, let id, let season, let number) = episode.playback else { throw AetherCatalogError.invalidRoute }
        let path = try AetherCatalog.playbackPath(type: kind, id: id, season: season, episode: number)
        let expected = kind == "movie" ? AetherCatalog.canonical(kind, id: id)
            : AetherCatalog.canonical(kind, id: id).appendingPathComponent("season/\(season!)/episode/\(number!)")
        guard episode.url == expected else { throw AetherCatalogError.invalidRoute }
        let domain = try await resolveDomain(refresh)
        try Task.checkCancellation()
        guard let origin = AetherDomainPolicy.origin(domain), origin == domain else { throw AetherCatalogError.invalidRoute }
        let url = domain.appendingPathComponent(path)
        return ResolvedPlayback(url: url, headers: [:], webURL: url, isWeb: true)
    }
    private func loadGenres() async {
        guard (try? authorization()) != nil else { return }
        let generation = cacheGeneration
        let defaults = AetherCatalog.listRows.map { AnimeCategory(title: $0.title, path: $0.path, group: "Danh sách phim") }
        // Keep fallback lists visible even if optional taxonomy endpoints fail.
        var genres: [AnimeCategory] = []
        for type in ["movie", "tv"] {
            if let json = try? await request("genre/\(type)/list") { genres += AetherCatalog.categories(json, type: type) }
        }
        if !Task.isCancelled, cacheGeneration == generation { categories = defaults + genres }
    }
    private func authorization() throws -> (value: String, language: String) {
        guard let raw = credential()?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { throw AetherCatalogError.missingCredential }
        guard raw.utf8.count <= 8192, !raw.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw AetherCatalogError.invalidCredential }
        let language = self.language()
        guard language.range(of: #"^[A-Za-z]{2}(?:-[A-Za-z]{2})?$"#, options: .regularExpression) != nil else { throw AetherCatalogError.invalidData }
        if credentialIdentity != raw || languageIdentity != language {
            invalidate(); credentialIdentity = raw; languageIdentity = language
        }
        return (raw, language)
    }
    private func request(_ path: String, query: [URLQueryItem] = []) async throws -> AetherCatalog.Object {
        try Task.checkCancellation()
        let auth = try authorization()
        let generation = cacheGeneration
        var components = URLComponents(url: AetherCatalog.api.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query + [.init(name: "language", value: auth.language)]
        let key = components.url!.absoluteString // Cache keys never contain credentials.
        if let cached = jsonCache[key], Date().timeIntervalSince(cached.date) < 300 { return cached.object }
        let isKey = auth.value.range(of: #"^[a-fA-F0-9]{32}$"#, options: .regularExpression) != nil
        if isKey { components.queryItems!.append(.init(name: "api_key", value: auth.value)) }
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        if !isKey { request.setValue("Bearer " + auth.value, forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request, delegate: AetherRedirectGuard(hosts: ["api.themoviedb.org"])) }
        catch {
            try Task.checkCancellation()
            throw AetherCatalogError.unavailable // Never expose a signed/key-bearing request URL.
        }
        try Task.checkCancellation()
        // A settings refresh may revoke/change credentials while URLSession is
        // suspended. Its older response must not refill the new metadata cache.
        _ = try authorization()
        guard cacheGeneration == generation else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse, http.url?.scheme == "https", http.url?.host == "api.themoviedb.org",
              http.url?.user == nil, http.url?.password == nil, http.url?.port == nil || http.url?.port == 443 else { throw AetherCatalogError.invalidData }
        if http.statusCode == 401 || http.statusCode == 403 { throw AetherCatalogError.invalidCredential }
        guard (200..<300).contains(http.statusCode) else { throw AetherCatalogError.http(http.statusCode) }
        guard data.count <= 8 * 1024 * 1024,
              let json = try? JSONSerialization.jsonObject(with: data) as? AetherCatalog.Object else { throw AetherCatalogError.invalidData }
        if jsonCache.count >= 80 { jsonCache.removeAll() }
        jsonCache[key] = (Date(), json)
        return json
    }
}

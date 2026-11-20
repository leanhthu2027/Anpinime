import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// SvelteKit streams a reference table and separate deferred chunks as NDJSON.
struct MiruroPage {
    typealias Object = [String: Any]
    private let nodes: [[Any]]
    private let chunks: [Int: [Any]]

    init(_ data: Data) throws {
        guard data.count <= 8 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw AnimeServiceError.invalidResponse
        }
        var nodes: [[Any]] = []
        var chunks: [Int: [Any]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let packet = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? Object
            if let entries = packet?["nodes"] as? [Object] {
                nodes += entries.compactMap { $0["data"] as? [Any] }
            } else if packet?["type"] as? String == "chunk", let id = packet?["id"] as? Int,
                      let table = packet?["data"] as? [Any] {
                chunks[id] = table
            }
        }
        guard !nodes.isEmpty else { throw AnimeServiceError.emptyData }
        self.nodes = nodes
        self.chunks = chunks
    }

    func field(_ key: String) -> Any? {
        for table in nodes.reversed() {
            if let root = table.first as? Object, let index = root[key] as? Int {
                var budget = 100_000
                return decode(index, in: table, depth: 0, budget: &budget)
            }
        }
        return nil
    }

    private func decode(_ index: Int, in table: [Any], depth: Int, budget: inout Int) -> Any? {
        guard table.indices.contains(index), depth < 48, budget > 0 else { return nil }
        budget -= 1
        let value = table[index]
        if let object = value as? Object {
            var decoded: Object = [:]
            for (key, reference) in object {
                if let next = reference as? Int {
                    decoded[key] = decode(next, in: table, depth: depth + 1, budget: &budget)
                }
            }
            return decoded
        }
        if let array = value as? [Any] {
            if array.first as? String == "Promise", array.count == 2,
               let reference = array[1] as? Int, table.indices.contains(reference),
               let id = table[reference] as? Int, let chunk = chunks[id] {
                return decode(0, in: chunk, depth: depth + 1, budget: &budget)
            }
            return array.compactMap { entry -> Any? in
                guard let next = entry as? Int else { return nil }
                return decode(next, in: table, depth: depth + 1, budget: &budget)
            }
        }
        return value is NSNull ? nil : value
    }
}

@MainActor
final class MiruroProvider: MovieSourceProviding {
    typealias Object = MiruroPage.Object

    let baseURL = URL(string: "https://miruro.cx/")!
    let categories: [AnimeCategory] = [
        .init(title: "Đang chiếu", path: "airing"),
        .init(title: "Nổi bật", path: "featured")
    ]
    let notice = ""
    private let session: URLSession
    private var cachedSections: [AnimeSection] = []

    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        self.session = session ?? URLSession(configuration: config)
    }

    func invalidate() { cachedSections = [] }

    func home(onInitial: ([AnimeSection]) -> Void) async throws -> [AnimeSection] {
        let page = try MiruroPage(await request(dataURL(baseURL)))
        var sections: [AnimeSection] = []
        if let hero = page.field("hero") as? [Object] {
            let items = catalogItems(hero)
            if !items.isEmpty { sections.append(.init(title: "Nổi bật", items: items, categoryPath: "featured")) }
        }
        // The initial HTML references deferred rails. Keep the visible hero
        // independent of their availability, as the site does.
        if let rails = page.field("rails") {
            let items = catalogItems(rows(in: rails))
            if !items.isEmpty { sections.append(.init(title: "Đang chiếu", items: items, categoryPath: "airing")) }
        }
        guard !sections.isEmpty else { throw AnimeServiceError.emptyData }
        cachedSections = sections
        onInitial(sections)
        return sections
    }

    func list(path: String, page: Int) async throws -> [Anime] {
        guard page == 1 else { return [] }
        if cachedSections.isEmpty { _ = try await home { _ in } }
        return cachedSections.first(where: { $0.categoryPath == path })?.items ?? []
    }

    func search(_ query: String) async throws -> [Anime] {
        var route = URLComponents(url: baseURL.appendingPathComponent("api/search/browse"), resolvingAgainstBaseURL: false)!
        route.queryItems = [.init(name: "q", value: query), .init(name: "limit", value: "32"), .init(name: "type", value: "ANIME")]
        guard let url = route.url, let json = try JSONSerialization.jsonObject(with: await request(url)) as? Object,
              let items = json["data"] as? [Object] else { throw AnimeServiceError.invalidResponse }
        return catalogItems(items)
    }

    func detail(_ anime: Anime) async throws -> AnimeDetail {
        guard anime.source == .miruro, watchRoute(anime.url) else { throw AnimeServiceError.invalidURL }
        let page = try MiruroPage(await request(dataURL(anime.url)))
        return try detail(from: page, anime: anime)
    }

    func detail(from page: MiruroPage, anime: Anime) throws -> AnimeDetail {
        guard let media = page.field("media") as? Object else { throw AnimeServiceError.emptyData }
        let decoded = page.field("episodesData") as? Object
        let items = decoded?["episodes"] as? [Object] ?? []
        var seen = Set<Double>()
        let episodes = items.compactMap { row -> Episode? in
            guard let number = row["number"] as? NSNumber, number.doubleValue.isFinite,
                  number.doubleValue > 0, number.doubleValue < 100_000,
                  seen.insert(number.doubleValue).inserted,
                  var route = URLComponents(url: anime.url, resolvingAgainstBaseURL: false) else { return nil }
            route.queryItems = [.init(name: "ep", value: number.stringValue)]
            guard let url = route.url else { return nil }
            let label = "Tập " + number.stringValue
            let name = row["title"] as? String
            return Episode(title: name.flatMap { $0.isEmpty ? nil : label + " · " + $0 } ?? label,
                           url: url, number: Int(exactly: number.doubleValue), season: "Miruro",
                           source: .miruro)
        }
        let cover = media["coverImage"] as? Object
        return AnimeDetail(title: title(media) ?? anime.title,
                           posterURL: Self.remoteURL(cover?["large"]) ?? anime.imageURL,
                           bannerURL: Self.remoteURL(media["bannerImage"]) ?? anime.bannerURL,
                           summary: (media["description"] as? String ?? anime.summary).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression),
                           info: [media["format"] as? String, (media["seasonYear"] as? Int).map(String.init)].compactMap { $0 }.joined(separator: " · "),
                           episodes: episodes)
    }

    func resolve(_ episode: Episode, refresh: Bool) async throws -> ResolvedPlayback {
        guard episode.source == .miruro, watchRoute(episode.url),
              let rawNumber = URLComponents(url: episode.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "ep" })?.value,
              let number = Double(rawNumber) else { throw AnimeServiceError.invalidURL }
        let page = try MiruroPage(await request(dataURL(episode.url)))
        let options = streams(from: page, episode: number)
        guard let first = options.first else { throw AnimeServiceError.emptyData }
        return ResolvedPlayback(url: first.url, headers: first.headers, webURL: nil, isWeb: false,
                                nativeFallbacks: Array(options.dropFirst()), captions: first.captions)
    }

    func streams(from page: MiruroPage, episode: Double) -> [NativeStream] {
        guard let data = page.field("sourcesData") as? Object,
              (data["episodeNumber"] as? NSNumber)?.doubleValue == episode,
              let tracks = data["tracks"] as? [Object] else { return [] }
        var seen = Set<URL>()
        var options: [NativeStream] = []
        // Soft subs first, then subtitled video and dubbed audio.
        for track in ["ssub", "sub", "dub", "raw"] {
            for row in tracks where row["track"] as? String == track {
                for provider in row["providers"] as? [Object] ?? [] {
                    for server in provider["servers"] as? [Object] ?? [] {
                        let headers = (server["headers"] as? [String: String] ?? [:]).filter { name, value in
                            ["origin", "referer", "user-agent"].contains(name.lowercased())
                                && !value.contains("\r") && !value.contains("\n")
                        }
                        let captions = (provider["subtitles"] as? [Object] ?? []).compactMap { subtitle -> RemoteCaption? in
                            guard let url = Self.remoteURL(subtitle["file"]), let label = subtitle["label"] as? String else { return nil }
                            return RemoteCaption(title: label, language: subtitle["language"] as? String ?? "", url: url, headers: headers)
                        }
                        for stream in server["streams"] as? [Object] ?? [] {
                            guard ["hls", "mp4"].contains(stream["format"] as? String ?? ""),
                                  let url = Self.remoteURL(stream["url"]), seen.insert(url).inserted else { continue }
                            options.append(NativeStream(url: url, headers: headers, captions: captions))
                        }
                    }
                }
            }
        }
        return Array(options.prefix(12))
    }

    func catalogItems(_ rows: [Object]) -> [Anime] {
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let id = row["animeId"] as? String ?? row["id"] as? String,
                  id.range(of: #"^[A-Za-z0-9_-]{1,100}$"#, options: .regularExpression) != nil,
                  let title = title(row), seen.insert(id).inserted else { return nil }
            let slug = title.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
                .lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let url = baseURL.appendingPathComponent("watch").appendingPathComponent(id).appendingPathComponent(slug.isEmpty ? "anime" : slug)
            let count = (row["episode"] ?? row["episodeCount"] ?? row["episode_count"]) as? NSNumber
            return Anime(title: title, url: url, imageURL: Self.remoteURL(row["coverUrl"] ?? row["cover_url"]),
                         bannerURL: Self.remoteURL(row["backgroundUrl"] ?? row["banner_url"]),
                         episodeText: count.map { "Tập " + $0.stringValue } ?? "", quality: row["format"] as? String ?? "",
                         score: (row["averageScore"] ?? row["average_score"]).flatMap { ($0 as? NSNumber)?.stringValue } ?? "",
                         source: .miruro)
        }
    }

    private func rows(in value: Any, depth: Int = 0) -> [Object] {
        guard depth < 8 else { return [] }
        if let object = value as? Object {
            if title(object) != nil, object["id"] != nil || object["animeId"] != nil { return [object] }
            return object.keys.sorted().flatMap { rows(in: object[$0]!, depth: depth + 1) }
        }
        return (value as? [Any] ?? []).flatMap { rows(in: $0, depth: depth + 1) }
    }

    private func title(_ row: Object) -> String? {
        let names = row["title"] as? Object
        return [names?["english"], names?["romaji"], names?["native"]].compactMap { $0 as? String }.first { !$0.isEmpty }
    }

    private func watchRoute(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == baseURL.host && url.pathComponents.count == 4 && url.pathComponents[1] == "watch"
    }

    private func dataURL(_ url: URL) -> URL {
        var route = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        route.path = route.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        route.path = (route.path.isEmpty ? "" : "/" + route.path) + "/__data.json"
        route.queryItems = (route.queryItems ?? []) + [.init(name: "x-sveltekit-invalidated", value: "11")]
        return route.url!
    }

    private func request(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json,text/sveltekit-data", forHTTPHeaderField: "Accept")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw AnimeServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AnimeServiceError.http(http.statusCode) }
        guard http.url?.host == baseURL.host, data.count <= 8 * 1024 * 1024 else { throw AnimeServiceError.invalidResponse }
        return data
    }

    private static func remoteURL(_ value: Any?) -> URL? {
        guard let string = value as? String, let url = URL(string: string), url.scheme == "https",
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

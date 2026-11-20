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
            if let entries = packet?["nodes"] as? [Any] {
                nodes += entries.compactMap { ($0 as? Object)?["data"] as? [Any] }
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
        .init(title: "Thịnh hành", path: "sort=TRENDING_DESC"),
        .init(title: "Phổ biến", path: "sort=POPULARITY_DESC"),
        .init(title: "Điểm cao", path: "sort=SCORE_DESC"),
        .init(title: "Đang chiếu", path: "status=RELEASING"),
        .init(title: "Sắp chiếu", path: "status=NOT_YET_RELEASED"),
        .init(title: "Trọn bộ", path: "status=FINISHED"),
        .init(title: "Phim lẻ", path: "format=MOVIE"),
        .init(title: "Phim bộ", path: "format=TV"),
        .init(title: "OVA", path: "format=OVA")
    ] + ["Action", "Adventure", "Comedy", "Drama", "Fantasy", "Horror", "Mecha",
         "Mystery", "Psychological", "Romance", "Sci-Fi", "Slice of Life", "Sports",
         "Supernatural", "Thriller"].map { AnimeCategory(title: $0, path: "genre=" + $0) }
    let notice = ""
    private let session: URLSession
    private var initialStreams: (url: URL, date: Date, streams: [NativeStream])?

    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        self.session = session ?? URLSession(configuration: config)
    }

    func invalidate() { initialStreams = nil }

    func home(onInitial: ([AnimeSection]) -> Void) async throws -> [AnimeSection] {
        let page = try MiruroPage(await request(baseURL.appendingPathComponent("__data.json")))
        let rails = page.field("rails") as? Object
        let side = page.field("sideLists") as? Object
        var sections: [AnimeSection] = []
        func append(_ title: String, _ rows: Any?, path: String? = nil) {
            let items = catalogItems(rows as? [Object] ?? [])
            if !items.isEmpty { sections.append(.init(title: title, items: items, categoryPath: path)) }
        }
        append("Nổi bật", page.field("hero") ?? page.field("spotlight"))
        append("Tập mới · Phụ đề", (rails?["raw"] as? Object)?["latest"])
        append("Tập mới · Lồng tiếng", (rails?["dub"] as? Object)?["latest"])
        append("Đang chiếu", side?["airing"], path: "status=RELEASING")
        append("Sắp chiếu", side?["upcoming"], path: "status=NOT_YET_RELEASED")
        guard !sections.isEmpty else { throw AnimeServiceError.emptyData }
        onInitial(sections)
        return sections
    }

    func list(path: String, page: Int) async throws -> [Anime] {
        guard categories.contains(where: { $0.path == path }), page > 0,
              let separator = path.firstIndex(of: "=") else { return [] }
        let name = String(path[..<separator])
        var filters = [URLQueryItem(name: name, value: String(path[path.index(after: separator)...]))]
        if name != "sort" { filters.append(.init(name: "sort", value: "POPULARITY_DESC")) }
        return try await browse(filters, page: page)
    }

    func search(_ query: String) async throws -> [Anime] {
        try await browse([.init(name: "q", value: query)], page: 1)
    }

    private func browse(_ filters: [URLQueryItem], page: Int) async throws -> [Anime] {
        var route = URLComponents(url: baseURL.appendingPathComponent("api/search/browse"), resolvingAgainstBaseURL: false)!
        route.queryItems = filters + [.init(name: "type", value: "ANIME"), .init(name: "limit", value: "24"),
                                      .init(name: "page", value: String(page)), .init(name: "offset", value: String((page - 1) * 24))]
        guard let url = route.url, let json = try JSONSerialization.jsonObject(with: await request(url)) as? Object,
              let items = json["data"] as? [Object] else { throw AnimeServiceError.invalidResponse }
        return catalogItems(items)
    }

    func detail(_ anime: Anime) async throws -> AnimeDetail {
        guard anime.source == .miruro, watchRoute(anime.url) else { throw AnimeServiceError.invalidURL }
        let page = try await watchPage(anime.url, number: "1")
        let detail = try detail(from: page, anime: anime)
        if let first = detail.episodes.first(where: { $0.number == 1 }) {
            let options = streams(from: page, episode: 1)
            initialStreams = options.isEmpty ? nil : (first.url, Date(), options)
        }
        return detail
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
        let options: [NativeStream]
        if !refresh, let cached = initialStreams, cached.url == episode.url, Date().timeIntervalSince(cached.date) < 180 {
            options = cached.streams
        } else {
            var route = URLComponents(url: baseURL.appendingPathComponent("api/sources"), resolvingAgainstBaseURL: false)!
            route.queryItems = [.init(name: "id", value: episode.url.pathComponents[2]), .init(name: "n", value: rawNumber)]
            let json = try JSONSerialization.jsonObject(with: await request(route.url!)) as? Object
            options = streams(from: json, episode: number)
        }
        guard let first = options.first else { throw AnimeServiceError.emptyData }
        return ResolvedPlayback(url: first.url, headers: first.headers, webURL: nil, isWeb: false,
                                nativeFallbacks: Array(options.dropFirst()), captions: first.captions)
    }

    func streams(from page: MiruroPage, episode: Double) -> [NativeStream] {
        streams(from: page.field("sourcesData") as? Object, episode: episode)
    }

    private func streams(from data: Object?, episode: Double) -> [NativeStream] {
        guard let data, (data["episodeNumber"] as? NSNumber)?.doubleValue == episode,
              let tracks = data["tracks"] as? [Object] else { return [] }
        let order = data["providerOrder"] as? [String] ?? []
        let config = data["config"] as? [String: Object] ?? [:]
        var seen = Set<URL>()
        var options: [NativeStream] = []
        // Soft subs first, then subtitled video and dubbed audio.
        for track in ["ssub", "sub", "dub", "raw"] {
            for row in tracks where row["track"] as? String == track {
                let providers = row["providers"] as? [Object] ?? []
                func priority(_ provider: Object) -> Int {
                    order.firstIndex(of: provider["provider"] as? String ?? "") ?? order.count
                }
                for provider in providers.sorted(by: { priority($0) < priority($1) }) {
                    if let name = provider["provider"] as? String, config[name]?["visible"] as? Bool == false { continue }
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
            let names = row["title"] as? Object
            // Miruro displays the selected language but canonicalizes watch URLs
            // using the shorter English/Romaji title, with English winning ties.
            let candidates = [names?["english"], names?["romaji"]].compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let routeTitle = candidates.min { $0.utf16.count < $1.utf16.count } ?? title
            let slug = routeTitle.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
                .lowercased().replacingOccurrences(of: #"[^a-z0-9\s-]"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"[\s-]+"#, with: "-", options: .regularExpression)
            var url = baseURL.appendingPathComponent("watch").appendingPathComponent(id)
            if !slug.isEmpty && slug != id { url.appendPathComponent(slug) }
            let count = (row["episode"] ?? row["episodeCount"] ?? row["episode_count"]) as? NSNumber
            return Anime(title: title, url: url, imageURL: Self.remoteURL(row["coverUrl"] ?? row["cover_url"]),
                         bannerURL: Self.remoteURL(row["backdropUrl"] ?? row["backgroundUrl"] ?? row["banner_url"] ?? row["background_url"]),
                         episodeText: count.map { "Tập " + $0.stringValue } ?? "", quality: row["format"] as? String ?? "",
                         score: ((row["averageScore"] ?? row["average_score"]) as? NSNumber).map { String(format: "%.1f", $0.doubleValue / 10) } ?? "",
                         summary: (row["description"] as? String ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression),
                         source: .miruro)
        }
    }

    private func title(_ row: Object) -> String? {
        let names = row["title"] as? Object
        return [names?["english"], names?["romaji"], names?["native"]].compactMap { $0 as? String }.first { !$0.isEmpty }
    }

    private func watchRoute(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == baseURL.host && url.user == nil && url.password == nil && url.port == nil
            && (3...4).contains(url.pathComponents.count) && url.pathComponents[1] == "watch"
    }

    private func watchPage(_ url: URL, number: String) async throws -> MiruroPage {
        var pageURL = url
        // Older saved cards may carry a noncanonical slug. SvelteKit can
        // return a JSON redirect instead of following it as an HTTP redirect.
        for _ in 0..<3 {
            var route = URLComponents(url: pageURL.appendingPathComponent("__data.json"), resolvingAgainstBaseURL: false)!
            route.queryItems = [.init(name: "ep", value: number), .init(name: "x-sveltekit-invalidated", value: "01")]
            let data = try await request(route.url!)
            if let packet = try? JSONSerialization.jsonObject(with: data) as? Object,
               packet["type"] as? String == "redirect" {
                guard let location = packet["location"] as? String,
                      let next = URL(string: location, relativeTo: pageURL)?.absoluteURL,
                      watchRoute(next), next.pathComponents[2] == url.pathComponents[2],
                      next.path != pageURL.path else { throw AnimeServiceError.invalidResponse }
                pageURL = next
                continue
            }
            return try MiruroPage(data)
        }
        throw AnimeServiceError.invalidResponse
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

import Foundation
import CoreFoundation

/// Metadata IDs use TMDB's stable namespace; a mirror switch cannot change
/// movie/search/history/episode identity. No Aether catalog API is assumed.
enum AetherCatalog {
    typealias Object = [String: Any]
    static let api = URL(string: "https://api.themoviedb.org/3/")!
    static let site = URL(string: "https://www.themoviedb.org/")!
    static let listRows: [(title: String, path: String)] = [
        ("Thịnh hành", "tmdb/trending"), ("Phim mới", "tmdb/new"),
        ("Phim lẻ", "tmdb/movie"), ("Phim bộ", "tmdb/tv")
    ]
    struct Identity: Equatable { let type: String; let id: Int }
    static func integer(_ value: Any?) -> Int? {
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
           n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue,
           n.doubleValue >= 0, n.doubleValue < Double(Int.max) { return n.intValue }
        return nil
    }
    static func text(_ value: Any?) -> String { (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    static func identity(_ url: URL) -> Identity? {
        guard url.scheme == "https", url.host == site.host, url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 2, ["movie", "tv"].contains(parts[0]),
              parts[1].range(of: #"^[1-9][0-9]*$"#, options: .regularExpression) != nil,
              let id = Int(parts[1]) else { return nil }
        return Identity(type: parts[0], id: id)
    }
    static func canonical(_ type: String, id: Int) -> URL { site.appendingPathComponent(type).appendingPathComponent(String(id)) }
    static func image(_ value: Any?, size: String) -> URL? {
        let value = text(value)
        guard value.hasPrefix("/"), !value.hasPrefix("//"), !value.contains(".."), !value.contains("?"), !value.contains("#"), !value.contains(":") else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/" + size)!.appendingPathComponent(String(value.dropFirst()))
    }
    static func items(_ object: Object, type: String? = nil) -> [Anime] {
        var seen = Set<String>()
        return (object["results"] as? [Object] ?? []).compactMap { row in
            let kind = type ?? text(row["media_type"])
            guard ["movie", "tv"].contains(kind), let id = integer(row["id"]), id > 0,
                  seen.insert(kind + ":" + String(id)).inserted else { return nil }
            let title = [text(row["title"]), text(row["name"]), text(row["original_title"]), text(row["original_name"])].first { !$0.isEmpty } ?? ""
            guard !title.isEmpty else { return nil }
            let original = text(row[kind == "movie" ? "original_title" : "original_name"])
            let date = text(row[kind == "movie" ? "release_date" : "first_air_date"])
            let score = (row["vote_average"] as? NSNumber).map { String(format: "%.1f", $0.doubleValue) } ?? ""
            return Anime(title: title, subtitle: original == title ? "" : original,
                url: canonical(kind, id: id), imageURL: image(row["poster_path"], size: "w500"),
                bannerURL: image(row["backdrop_path"], size: "w1280"), episodeText: kind == "tv" ? "Phim bộ" : "Phim lẻ",
                quality: "", score: score, summary: text(row["overview"]), info: String(date.prefix(4)),
                source: .aether, catalogLabel: "TMDB")
        }
    }
    static func listRoute(_ path: String) throws -> (path: String, type: String?, query: [URLQueryItem]) {
        switch path {
        case "", "tmdb/trending": return ("trending/all/day", nil, [])
        case "tmdb/new": return ("movie/now_playing", "movie", [])
        case "tmdb/movie": return ("movie/popular", "movie", [])
        case "tmdb/tv": return ("tv/popular", "tv", [])
        default:
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 4, parts[0] == "tmdb", parts[1] == "genre",
                  ["movie", "tv"].contains(parts[2]), parts[3].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let genre = Int(parts[3]), genre > 0 else { throw AetherCatalogError.invalidRoute }
            return ("discover/" + parts[2], parts[2], [.init(name: "with_genres", value: String(genre))])
        }
    }
    static func categories(_ genres: Object, type: String) -> [AnimeCategory] {
        (genres["genres"] as? [Object] ?? []).compactMap { row in
            guard let id = integer(row["id"]), id > 0, !text(row["name"]).isEmpty else { return nil }
            return AnimeCategory(title: text(row["name"]), path: "tmdb/genre/\(type)/\(id)", group: type == "movie" ? "Thể loại phim lẻ" : "Thể loại phim bộ")
        }
    }
    /// Exact route templates from Streambert src/utils/api.js; compatibility
    /// on current mirrors still requires a live/iPhone check.
    static func playbackPath(type: String, id: Int, season: Int?, episode: Int?) throws -> String {
        guard id > 0 else { throw AetherCatalogError.invalidRoute }
        if type == "movie", season == nil, episode == nil { return "media/tmdb-movie-\(id)" }
        if type == "tv", let season, season >= 0, let episode, episode > 0 { return "media/tmdb-tv-\(id)/\(season)/\(episode)" }
        throw AetherCatalogError.invalidRoute
    }
}

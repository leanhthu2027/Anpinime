import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Production provider/client under deterministic URLSession transport. No live
/// response or website route compatibility is claimed by these fixtures.
private final class CatalogProtocol: URLProtocol {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var failingPath: String?
    static var finalURL: URL?
    static var holdNext = false
    static var pendingResponse: (() -> Void)?
    static func reset(failing: String? = nil, finalURL: URL? = nil) {
        lock.lock(); defer { lock.unlock() }; requests = []; failingPath = failing; self.finalURL = finalURL
    }
    static var captured: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    static var responseHeld: Bool { lock.lock(); defer { lock.unlock() }; return pendingResponse != nil }
    static func holdResponse() { lock.lock(); defer { lock.unlock() }; holdNext = true }
    static func releaseResponse() {
        lock.lock(); let response = pendingResponse; pendingResponse = nil; lock.unlock()
        response?()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); let failure = Self.failingPath; let final = Self.finalURL; Self.lock.unlock()
        let path = request.url!.path
        let movie: [String: Any] = ["id": 41, "title": "Phim thử", "original_title": "Fixture Movie", "poster_path": "/poster.jpg", "backdrop_path": "/wide.jpg", "overview": "Tóm tắt", "media_type": "movie", "vote_average": 8.2]
        let series: [String: Any] = ["id": 41, "name": "Bộ thử", "media_type": "tv", "poster_path": "/series.jpg"]
        let body: [String: Any]
        switch path {
        case "/3/search/multi", "/3/trending/all/day": body = ["results": [movie, series, movie, ["id": 99, "name": "Actor", "media_type": "person"], ["id": -1, "title": "Invalid", "media_type": "movie"]]]
        case "/3/movie/now_playing", "/3/movie/popular", "/3/discover/movie": body = ["results": [movie]]
        case "/3/tv/popular", "/3/discover/tv": body = ["results": [series]]
        case "/3/genre/movie/list", "/3/genre/tv/list": body = ["genres": [["id": 28, "name": "Hành động"]]]
        case "/3/movie/41": body = movie
        case "/3/tv/41": body = ["id": 41, "name": "Bộ thử", "overview": "Series summary", "seasons": [["season_number": 2, "episode_count": 2], ["season_number": 0, "episode_count": 1], ["season_number": 1, "episode_count": 2], ["season_number": 3, "episode_count": 0]]]
        case "/3/tv/41/season/0": body = ["season_number": 0, "episodes": [["season_number": 0, "episode_number": 1]]]
        case "/3/tv/41/season/1": body = ["season_number": 1, "episodes": [["season_number": 1, "episode_number": 2], ["season_number": 1, "episode_number": 1]]]
        case "/3/tv/41/season/2": body = ["season_number": 2, "episodes": [["season_number": 2, "episode_number": 2], ["season_number": 2, "episode_number": 1]]]
        default: body = ["results": []]
        }
        let status = path == failure ? 503 : 200
        let data = try! JSONSerialization.data(withJSONObject: body)
        let deliver = { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: final ?? request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        }
        Self.lock.lock()
        if Self.holdNext {
            Self.holdNext = false; Self.pendingResponse = deliver; Self.lock.unlock()
        } else { Self.lock.unlock(); deliver() }
    }
}

@main struct AetherCatalogTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError("FAIL: " + message) }; checks += 1; print("PASS: " + message)
    }
    @MainActor static func main() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CatalogProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        CatalogProtocol.reset()
        var suppliedCredential: String? = "fixture-read-token"
        var suppliedLanguage = "vi-VN"
        let provider = AetherProvider(session: session, credential: { suppliedCredential }, language: { suppliedLanguage },
            resolveDomain: { _ in URL(string: "https://aether.cx/")! })
        var firstContent: [AnimeSection] = []
        let home = try await provider.home { firstContent = $0 }
        check(firstContent.count == 1 && firstContent[0].title == "Thịnh hành", "native first content publishes before optional home rows")
        check(Array(home.prefix(4)).map(\.title) == ["Thịnh hành", "Phim mới", "Phim lẻ", "Phim bộ"], "native Home uses existing section/card data for four requested rows")
        check(home.dropFirst(4).map(\.title) == ["Phim lẻ · Hành động", "Phim bộ · Hành động"]
              && home.dropFirst(4).map(\.categoryPath) == ["tmdb/genre/movie/28", "tmdb/genre/tv/28"]
              && home.dropFirst(4).allSatisfy { !$0.items.isEmpty }
              && CatalogProtocol.captured.filter { $0.url?.path.hasPrefix("/3/discover/") == true }.count == 2,
              "Home adds two bounded genre shelves with real movie/TV discovery data and See all routes")
        check(home[0].items.count == 2 && home[0].items.allSatisfy { $0.source == .aether }, "movie/TV keep distinct source identities and ignore people, duplicates and invalid IDs")
        check(Set(home[0].items.map(\.id)).count == 2, "same numeric movie/TV ID cannot collide")
        check(home[0].items[0].url.absoluteString == "https://www.themoviedb.org/movie/41", "catalog identity is stable and independent of mirror domain")
        check(home[0].items[0].imageURL?.absoluteString == "https://image.tmdb.org/t/p/w500/poster.jpg" && home[0].items[0].bannerURL?.absoluteString == "https://image.tmdb.org/t/p/w1280/wide.jpg", "poster and backdrop feed native cards at appropriate sizes")
        check(home[0].items[0].catalogLabel == "TMDB", "metadata provenance is explicit")
        check(provider.categories.contains { $0.path == "tmdb/genre/movie/28" } && provider.categories.contains { $0.path == "tmdb/genre/tv/28" }, "genre menus preserve movie and TV taxonomy separately")
        check(CatalogProtocol.captured.allSatisfy { $0.url?.host == "api.themoviedb.org" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-read-token" && $0.httpShouldHandleCookies == false }, "TMDB credential and account-free transport stay on the exact API host")
        let search = try await provider.search("Phim & dấu tiếng Việt")
        let searchRequest = CatalogProtocol.captured.last!
        let query = URLComponents(url: searchRequest.url!, resolvingAgainstBaseURL: false)!.queryItems!
        check(query.first { $0.name == "query" }?.value == "Phim & dấu tiếng Việt" && query.first { $0.name == "language" }?.value == "vi-VN", "search query and Vietnamese metadata language are encoded intact")
        let beforeCache = CatalogProtocol.captured.count
        _ = try await provider.search("Phim & dấu tiếng Việt")
        check(CatalogProtocol.captured.count == beforeCache, "metadata cache avoids repeated search requests")
        _ = try await provider.list(path: "tmdb/genre/movie/28", page: 3)
        let category = CatalogProtocol.captured.last!.url!
        check(category.path == "/3/discover/movie" && category.query?.contains("with_genres=28") == true && category.query?.contains("page=3") == true, "genre pagination uses documented TMDB discovery route")
        let movie = try await provider.detail(search.first { AetherCatalog.identity($0.url)?.type == "movie" }!)
        check(movie.episodes.count == 1, "movie detail exposes one native play entry")
        let moviePlayback = try await provider.resolve(movie.episodes[0])
        check(moviePlayback.url.absoluteString == "https://aether.cx/media/tmdb-movie-41" && moviePlayback.isWeb && moviePlayback.headers.isEmpty, "movie resolves the referenced Aether route without metadata credentials or native handoff")
        let tvItem = search.first { AetherCatalog.identity($0.url)?.type == "tv" }!
        let television = try await provider.detail(tvItem)
        check(television.episodes.map(\.season) == ["Ngoại truyện", "Phần 1", "Phần 1", "Phần 2", "Phần 2"] && television.episodes.map(\.number) == [1, 1, 2, 1, 2], "TV loads all nonempty seasons including specials, with numeric episode ordering")
        let secondSeason = television.episodes[3]
        let tvPlayback = try await provider.resolve(secondSeason)
        check(tvPlayback.url.absoluteString == "https://aether.cx/media/tmdb-tv-41/2/1", "TV playback uses the selected original season and episode numbers")
        let ids = television.episodes.map(\.id)
        let otherMirror = AetherProvider(session: session, credential: { "fixture-read-token" }, resolveDomain: { _ in URL(string: "https://aether.st/")! })
        let mirrorDetail = try await otherMirror.detail(tvItem)
        check(mirrorDetail.episodes.map(\.id) == ids, "domain recovery cannot rewrite episode/history IDs")
        let otherPlayback = try await otherMirror.resolve(secondSeason)
        check(otherPlayback.url.host == "aether.st", "only resolved playback origin changes across mirrors")
        let beforeLanguage = CatalogProtocol.captured.count
        suppliedLanguage = "en-US"; _ = try await provider.search("Phim & dấu tiếng Việt")
        check(CatalogProtocol.captured.count == beforeLanguage + 1, "metadata language changes invalidate old cache")
        suppliedCredential = "0123456789abcdef0123456789abcdef"
        _ = try await provider.search("API key query")
        let keyed = CatalogProtocol.captured.last!
        check(keyed.value(forHTTPHeaderField: "Authorization") == nil && URLComponents(url: keyed.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "api_key" }?.value == suppliedCredential, "an actual user API key uses supported api_key authentication")
        suppliedCredential = nil
        do { _ = try await provider.search("missing"); fatalError("Missing credential must not fabricate cards") } catch AetherCatalogError.missingCredential {}
        check(true, "missing credential reports actionable configuration error")
        suppliedCredential = "bad\nheader"
        do { _ = try await provider.search("bad"); fatalError("Header injection must fail") } catch AetherCatalogError.invalidCredential {}
        check(true, "credential containing header whitespace is rejected")
        for path in ["https://evil.example", "tmdb/genre/movie/28?api_key=x", "tmdb/genre/person/28", "tmdb/genre/movie/0", "tmdb/genre/movie/-1", "tmdb/genre/movie/../28"] {
            do { _ = try await provider.list(path: path); fatalError("Unsafe catalog route accepted") } catch AetherCatalogError.invalidRoute {}
        }
        check(true, "catalog paths cannot inject a host, credential or unsupported kind")
        check(AetherCatalog.identity(URL(string: "https://www.themoviedb.org.evil/movie/41")!) == nil && AetherCatalog.identity(URL(string: "https://www.themoviedb.org/movie/0")!) == nil, "foreign and zero movie identities are rejected")
        suppliedCredential = "fixture-read-token"; provider.invalidate()
        CatalogProtocol.reset(failing: "/3/tv/41/season/2")
        do { _ = try await provider.detail(tvItem); fatalError("Missing season must not return partial series") } catch AetherCatalogError.http(503) {}
        check(true, "failed season reports an error instead of truncating a TV playlist")
        CatalogProtocol.reset(failing: "/3/discover/movie"); provider.invalidate()
        let optionalShelfFailure = try await provider.home()
        check(optionalShelfFailure.count == 5 && Array(optionalShelfFailure.prefix(4)).map(\.title) == ["Thịnh hành", "Phim mới", "Phim lẻ", "Phim bộ"]
              && optionalShelfFailure.last?.title == "Phim bộ · Hành động",
              "one failed genre shelf preserves all base Home rows and the other genre")
        CatalogProtocol.reset(finalURL: URL(string: "https://evil.example/api")!); provider.invalidate()
        do { _ = try await provider.search("foreign response"); fatalError("Unexpected final origin accepted") } catch AetherCatalogError.invalidData {}
        check(true, "unexpected final response origin is not trusted")
        CatalogProtocol.reset(); provider.invalidate()
        let cancelled = Task { try await provider.search("cancel") }; cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancellation must propagate") } catch is CancellationError {}
        check(true, "cancelled metadata tasks cannot publish stale results")
        CatalogProtocol.reset(); CatalogProtocol.holdResponse()
        let stale = Task { try await provider.search("credential race") }
        for _ in 0..<1000 {
            if CatalogProtocol.responseHeld { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        check(CatalogProtocol.responseHeld, "credential-change regression suspends an actual provider request")
        suppliedCredential = "replacement-fixture-token"
        CatalogProtocol.releaseResponse()
        do { _ = try await stale.value; fatalError("Superseded credential response must not publish") } catch is CancellationError {}
        let beforeNewCredential = CatalogProtocol.captured.count
        _ = try await provider.search("credential race")
        check(CatalogProtocol.captured.count == beforeNewCredential + 1 && CatalogProtocol.captured.last?.value(forHTTPHeaderField: "Authorization") == "Bearer replacement-fixture-token",
              "in-flight responses from changed credentials neither publish nor refill the new cache")
        print("\(checks) native VIP catalog/provider checks passed")
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class MiruroFixture: URLProtocol {
    static var payload = Data()

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "miruro.cx" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let route = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let query = Dictionary(uniqueKeysWithValues: (route.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let data: Data
        switch route.path {
        case "/__data.json" where query.isEmpty:
            data = Data("""
            {"type":"data","nodes":[null,{"type":"data","data":[{"hero":1,"rails":8,"sideLists":10},[2],{"id":3,"title":4,"coverUrl":7},"show-fixture",{"english":5,"romaji":6},"The Ramparts of Ice Season 2","Koori no Jouheki 2nd Season","https://images.example/poster.jpg",["Promise",9],3,["Promise",11],4]}]}
            {"type":"chunk","id":3,"data":[{"raw":1,"dub":6},{"latest":2},[3],{"animeId":4,"title":5},"sub-fixture",{"english":7},{"latest":8},"Sub fixture",[9],{"animeId":10,"title":11},"dub-fixture",{"english":12},"Dub fixture"]}
            {"type":"chunk","id":4,"data":[{"airing":1,"upcoming":2},[3],[4],{"id":5,"title":7},{"id":6,"title":8},"airing","upcoming",{"english":9},{"english":10},"Airing","Upcoming"]}
            """.utf8)
        case "/api/search/browse" where query["q"] == "Fixture & test" && query["type"] == "ANIME" && query["page"] == "1" && query["offset"] == nil,
             "/api/search/browse" where query["genre"] == "Slice of Life" && query["offset"] == "24" && query["page"] == "2":
            data = Data(#"{"data":[{"id":"show-fixture","title":{"english":"The Ramparts of Ice Season 2","romaji":"Koori no Jouheki 2nd Season"},"cover_url":"https://images.example/poster.jpg","average_score":81}]}"#.utf8)
        case "/info/show-fixture/koori-no-jouheki-2nd-season/__data.json" where query["x-sveltekit-invalidated"] == "01":
            data = Data(#"{"type":"data","nodes":[{"data":[{"detail":1},{"title":2,"description":4,"cover_url":5},{"english":3},"Info fixture","Detailed summary","https://images.example/detail.jpg"]}]}"#.utf8)
        case "/schedule/__data.json" where query["x-sveltekit-invalidated"] == "01":
            data = Data(#"{"type":"data","nodes":[{"data":[{"entries":1,"weekStart":2},[3],1794787200,{"id":4,"airingAt":5,"episode":6,"track":7,"media":8},"sched-1",1794870000,1,"sub",{"id":9,"title":10},"show-fixture",{"english":11},"Fixture"]}]}"#.utf8)
        case "/api/schedule" where query["startAt"] == "1795392000" && query["track"] == "all":
            data = Data(#"[{"id":"next","airingAt":1795474800,"episode":2,"track":"dub","media":{"id":"show-fixture","title":{"english":"Fixture"}}}]"#.utf8)
        case "/watch/show-fixture/the-ramparts-of-ice-season-2/__data.json":
            data = Data(#"{"type":"redirect","location":"/watch/show-fixture/koori-no-jouheki-2nd-season?ep=1"}"#.utf8)
        case "/watch/show-fixture/koori-no-jouheki-2nd-season/__data.json" where query == ["ep":"1","x-sveltekit-invalidated":"01"]:
            data = Self.payload
        case "/api/sources" where query["id"] == "show-fixture" && query["n"] == "1.5":
            data = Data(#"{"episodeNumber":1.5,"tracks":[{"track":"ssub","providers":[{"provider":"sun","servers":[{"streams":[{"format":"hls","url":"https://cdn.example/special.m3u8"}]}]}]}]}"#.utf8)
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct MiruroProviderTests {
    @MainActor static func main() async throws {
        // NDJSON node + deferred episode and stream chunks, as captured by the
        // browser. Addresses are fixtures and never contain recorded playback tokens.
        MiruroFixture.payload = Data("""
        {"type":"data","nodes":[{"type":"skip"},{"type":"data","data":[{"media":1,"episodesData":5,"sourcesData":6},{"title":2,"format":4},{"english":3},"Fixture","TV",["Promise",7],["Promise",8],4,5]}]}
        {"type":"chunk","id":4,"data":[{"episodes":1},[2,5],{"number":3,"title":4},1,"Opening",{"number":6,"title":7},1.5,"Special"]}
        {"type":"chunk","id":5,"data":[{"episodeNumber":1,"tracks":2},1,[3],{"track":4,"providers":5},"ssub",[6],{"servers":7,"subtitles":18},[8,13],{"headers":9,"streams":11},{"Referer":10,"Authorization":10},"https://player.example/",[12],{"format":16,"url":17},{"streams":14},[15],{"format":16,"url":23},"hls","https://cdn.example/extensionless",[19],{"language":20,"label":21,"file":22},"vi","Tiếng Việt","https://cdn.example/caption.vtt","https://alt.example/video.m3u8"]}
        """.utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MiruroFixture.self]
        let provider = MiruroProvider(session: URLSession(configuration: config))
        let home = try await provider.home { _ in }
        precondition(home.first?.items.first?.source == .miruro && !ContentSource.miruro.isMovie)
        precondition(home.map(\.title) == ["Nổi bật","Tập mới · Phụ đề","Tập mới · Lồng tiếng","Đang chiếu","Sắp chiếu"])
        precondition(home.compactMap { $0.items.first?.url.pathComponents[2] } == ["show-fixture","sub-fixture","dub-fixture","airing","upcoming"])
        let matches = try await provider.search("Fixture & test")
        precondition(matches.count == 1 && matches.first?.imageURL?.host == "images.example")
        precondition(matches[0].url.lastPathComponent == "koori-no-jouheki-2nd-season" && matches[0].score == "8.1")
        let next = try await provider.list(path: "genre=Slice of Life", page: 2)
        precondition(next == matches)
        let old = Anime(title: "Old card", url: URL(string: "https://miruro.cx/watch/show-fixture/the-ramparts-of-ice-season-2")!,
                        imageURL: nil, episodeText: "", quality: "", score: "", source: .miruro)
        let restored = try await provider.detail(old)
        precondition(restored.episodes.count == 2)
        let detail = try await provider.detail(home[0].items[0])
        precondition(detail.episodes.count == 2 && detail.episodes.last?.url.query == "ep=1.5")
        precondition(detail.summary == "Detailed summary" && detail.posterURL?.lastPathComponent == "detail.jpg")
        let schedule = try await provider.schedule()
        precondition(schedule[.tuesday]?.first?.airTime == "06:00" && schedule[.tuesday]?.first?.anime.source == .miruro)
        let followingWeek = try await provider.schedule(weekOffset: 1)
        precondition(followingWeek[.tuesday]?.first?.track == "dub")
        let result = try await provider.resolve(detail.episodes[0], refresh: false)
        precondition(!result.isWeb && result.url.path == "/extensionless" && result.nativeFormat == "hls")
        precondition(result.headers == ["Referer": "https://player.example/"])
        precondition(result.captions.first?.language == "vi" && result.nativeFallbacks.first?.url.host == "alt.example")
        let special = try await provider.resolve(detail.episodes[1], refresh: false)
        precondition(special.url.lastPathComponent == "special.m3u8")
        let fixture = try MiruroPage(MiruroFixture.payload)
        precondition(provider.streams(from: fixture, episode: 2).isEmpty)

        let indirect = try MiruroPage(Data("""
        {"type":"data","nodes":[{"data":[{"value":1},["Promise",2],3,42]}]}
        {"type":"chunk","id":3,"data":[{"name":1},"indirect"]}
        {"type":"chunk","id":2,"data":[{"name":1},"direct"]}
        """.utf8))
        precondition((indirect.field("value") as? [String: Any])?["name"] as? String == "indirect")
        let missing = try MiruroPage(Data(#"{"type":"data","nodes":[{"data":[{"value":1},["Promise",4]]}]}"#.utf8))
        precondition(missing.field("value") == nil)
        if let path = ProcessInfo.processInfo.environment["ANPINIME_MIRURO_HOME_CAPTURE"] {
            let capturedHome = try MiruroPage(Data(contentsOf: URL(fileURLWithPath: path)))
            precondition((capturedHome.field("hero") as? [[String: Any]])?.count == 10)
            let rails = capturedHome.field("rails") as? [String: Any]
            precondition(((rails?["raw"] as? [String: Any])?["latest"] as? [[String: Any]])?.count == 54)
            precondition(((rails?["dub"] as? [String: Any])?["latest"] as? [[String: Any]])?.count == 41)
            let sides = capturedHome.field("sideLists") as? [String: Any]
            precondition((sides?["airing"] as? [[String: Any]])?.count == 10)
            precondition((sides?["upcoming"] as? [[String: Any]])?.count == 10)
            print("PASS: captured Miruro Home reconstructs all five groups")
        }
        if let path = ProcessInfo.processInfo.environment["ANPINIME_MIRURO_INFO_CAPTURE"] {
            let captured = try MiruroPage(Data(contentsOf: URL(fileURLWithPath: path)))
            let info = captured.field("detail") as? [String: Any]
            precondition(info?["description"] is String && info?["cover_url"] is String)
            print("PASS: captured Miruro Info reconstructs detail metadata")
        }
        if let path = ProcessInfo.processInfo.environment["ANPINIME_MIRURO_SCHEDULE_CAPTURE"] {
            let captured = try MiruroPage(Data(contentsOf: URL(fileURLWithPath: path)))
            let entries = captured.field("entries") as? [[String: Any]] ?? []
            let parsed = provider.scheduleEntries(entries, now: Date(timeIntervalSince1970: 0))
            precondition(entries.count == 254 && parsed.values.reduce(0, { $0 + $1.count }) == 254)
            precondition(parsed.values.flatMap { $0 }.allSatisfy { $0.anime.source == .miruro && $0.anime.url.path.hasPrefix("/watch/") })
            print("PASS: captured Miruro schedule reconstructs 254 source-specific entries")
        }
        if let path = ProcessInfo.processInfo.environment["ANPINIME_MIRURO_CAPTURE"] {
            let observed = try MiruroPage(Data(contentsOf: URL(fileURLWithPath: path)))
            let title = Anime(title: "Black Clover Season 2", url: URL(string: "https://miruro.cx/watch/sample/black-clover-season-2")!,
                              imageURL: nil, episodeText: "", quality: "", score: "", source: .miruro)
            let capturedDetail = try provider.detail(from: observed, anime: title)
            let streams = provider.streams(from: observed, episode: 1)
            precondition(capturedDetail.episodes.count == 7 && streams.count > 12 && !streams[0].captions.isEmpty)
            print("PASS: uploaded Miruro HAR watch response reconstructs seven episodes, native alternatives and caption tracks")
        }
        print("PASS: Miruro Home, search, episode requests, HLS, safe headers, captions and native fallbacks")
    }
}

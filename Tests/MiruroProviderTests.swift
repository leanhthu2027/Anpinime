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
        case "/__data.json" where query["x-sveltekit-invalidated"] == "11":
            data = Data(#"{"type":"data","nodes":[{"type":"data","data":[{"hero":1},[2],{"id":3,"title":4,"coverUrl":6},"show-fixture",{"english":5},"Fixture","https://images.example/poster.jpg"]}]}"#.utf8)
        case "/api/search/browse" where query["q"] == "Fixture & test" && query["type"] == "ANIME":
            data = Data(#"{"data":[{"id":"show-fixture","title":{"english":"Fixture"},"cover_url":"https://images.example/poster.jpg"}]}"#.utf8)
        case "/watch/show-fixture/fixture/__data.json" where query["x-sveltekit-invalidated"] == "11" && (query["ep"] == nil || query["ep"] == "1"):
            data = Self.payload
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
        let matches = try await provider.search("Fixture & test")
        precondition(matches.count == 1 && matches.first?.imageURL?.host == "images.example")
        let detail = try await provider.detail(matches[0])
        precondition(detail.episodes.count == 2 && detail.episodes.last?.url.query == "ep=1.5")
        let result = try await provider.resolve(detail.episodes[0], refresh: false)
        precondition(!result.isWeb && result.url.path == "/extensionless")
        precondition(result.headers == ["Referer": "https://player.example/"])
        precondition(result.captions.first?.language == "vi" && result.nativeFallbacks.first?.url.host == "alt.example")
        let fixture = try MiruroPage(MiruroFixture.payload)
        precondition(provider.streams(from: fixture, episode: 2).isEmpty)

        if let path = ProcessInfo.processInfo.environment["ANPINIME_MIRURO_CAPTURE"] {
            let observed = try MiruroPage(Data(contentsOf: URL(fileURLWithPath: path)))
            let title = Anime(title: "Black Clover Season 2", url: URL(string: "https://miruro.cx/watch/sample/black-clover-season-2")!,
                              imageURL: nil, episodeText: "", quality: "", score: "", source: .miruro)
            let capturedDetail = try provider.detail(from: observed, anime: title)
            let streams = provider.streams(from: observed, episode: 1)
            precondition(capturedDetail.episodes.count == 7 && streams.count > 1 && !streams[0].captions.isEmpty)
            print("PASS: uploaded Miruro HAR watch response reconstructs seven episodes, native alternatives and caption tracks")
        }
        print("PASS: Miruro Home, search, episode requests, HLS, safe headers, captions and native fallbacks")
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main struct AetherStreamTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard value() else { fatalError(message) }
    }
    static func reject(_ message: String, _ body: () throws -> Void) {
        checks += 1
        do { try body(); fatalError(message) } catch { }
    }
    static func main() async throws {
        // Captured from the exact live Aether vendor bundle with Date.now fixed.
        // Covers both short and longer plaintexts plus request expiry bytes.
        let vectors = [
            ("550", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAfQaY4bZuT-6iSY_fSf3gpsWGCP5NQFZ8jV2K"),
            ("1399", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA-u9FkRN-_GttzC8t7Ts1V8GAAcdNQFYZvJDTSA"),
            ("1000000", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAXzU2rUltgxjbFl2zljRUMMGDCM59cGYZ2cRK7fKhFw")]
        for (id, expected) in vectors {
            check(AetherProviderToken.make(id: id, now: Date(timeIntervalSince1970: 1700000000)) == expected, "provider token mismatch")
        }
        let date = Date(timeIntervalSince1970: 1700000000)
        let movie = try AetherStreamClient.requestURL(mediaType: "movie", id:550, season:nil, episode:nil, now:date)
        check(movie.path.hasPrefix("/api/b/movie/"), "movie endpoint")
        check(movie.query == "multiLang=0", "upstream query contract")
        let show = try AetherStreamClient.requestURL(mediaType:"tv",id:1399,season:0,episode:1,now:date)
        check(show.path.hasSuffix("/0/1"), "special season route")
        reject("invalid media accepted") { _ = try AetherStreamClient.requestURL(mediaType:"other",id:550,season:nil,episode:nil,now:date) }
        reject("missing episode accepted") { _ = try AetherStreamClient.requestURL(mediaType:"tv",id:1399,season:1,episode:nil,now:date) }
        reject("negative id accepted") { _ = try AetherStreamClient.requestURL(mediaType:"movie",id:-1,season:nil,episode:nil,now:date) }
        for value in ["http://stream.example/movie.mp4", "file:///tmp/movie.mp4", "https://user:password@stream.example/movie.mp4", "javascript:play()", "https://stream.example/movie.mp4#hidden"] {
            check(AetherStreamClient.safeURL(value) == nil, "unsafe media URL accepted")
        }
        let fixture = Data(#"{"sourceId":"mwVault","stream":{"type":"file","headers":{"Referer":"https://vidlink.pro/","Host":"wrong.example","Origin":"bad\r\nInjected: yes"},"qualities":{"360":{"type":"mp4","url":"https://stream.example/360.mp4"},"1080":{"type":"mp4","url":"https://stream.example/1080.mp4","headers":{"User-Agent":"native-agent"}},"720":{"type":"mp4","url":"https://user:password@stream.example/720.mp4"}},"captions":[{"id":"english","url":"https://caption.example/en.srt","language":"English","type":"srt"},{"id":"vietnamese","url":"https://caption.example/vi.vtt","language":"Tiếng Việt","type":"vtt"},{"id":"duplicate","url":"https://caption.example/en.srt","language":"en"},{"id":"invalid","url":"javascript:fake","language":"en"}]}}"#.utf8)
        let decoded = try AetherStreamClient.decode(fixture)
        check(decoded.serverID == "vidlink", "provider identity")
        check(decoded.variants.map(\.id) == ["1080","360"], "quality ordering or unsafe variant filtering")
        check(decoded.variants[0].headers["Referer"] == "https://vidlink.pro/", "required header lost")
        check(decoded.variants[0].headers["User-Agent"] == "native-agent", "per-variant header lost")
        check(decoded.variants[0].headers["Host"] == nil && decoded.variants[0].headers["Origin"] == nil, "unsafe headers accepted")
        check(decoded.captions.count == 2, "caption URL validation or dedupe")
        check(decoded.captions.map(\.language) == ["en","vi"], "caption language aliases")
        check(AetherStreamClient.cleanHeaders(["referer":"https://provider.example/", "user-agent":"agent"])
                == ["Referer":"https://provider.example/", "User-Agent":"agent"], "MPV header case normalization")
        let hls = try AetherStreamClient.decode(Data(#"{"stream":{"type":"hls","playlist":"https://stream.example/master.m3u8","headers":{"Origin":"https://provider.example"}}}"#.utf8))
        check(hls.variants.count == 1 && hls.variants[0].id == "auto", "HLS master handling")
        check(hls.variants[0].headers["Origin"] == "https://provider.example", "HLS request headers")
        reject("HTML failure accepted") { _ = try AetherStreamClient.decode(Data("<html>blocked</html>".utf8)) }
        reject("empty streams accepted") { _ = try AetherStreamClient.decode(Data(#"{"stream":{"type":"file","qualities":{}}}"#.utf8)) }
        reject("unsupported stream accepted") { _ = try AetherStreamClient.decode(Data(#"{"stream":{"type":"iframe","url":"https://site.example/page"}}"#.utf8)) }
        let client = AetherStreamClient(transport: { request in
            check(request.url == movie, "transport endpoint mismatch")
            check(request.value(forHTTPHeaderField:"Referer") == "https://vidlink.pro/", "upstream referer")
            check(request.value(forHTTPHeaderField:"Authorization") == nil, "metadata credential leaked to stream host")
            return (fixture,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        }, now:{ date })
        let resolved = try await client.resolve(mediaType:"movie",id:550,season:nil,episode:nil,serverID:"vidlink")
        check(resolved == decoded, "native transport result")
        let denied = AetherStreamClient(transport:{ request in
            (Data(),HTTPURLResponse(url:request.url!,statusCode:403,httpVersion:nil,headerFields:nil)!)
        })
        do { _ = try await denied.resolve(mediaType:"movie",id:550,season:nil,episode:nil,serverID:"vidlink"); fatalError("HTTP failure accepted") }
        catch AetherStreamError.rejected(403) { checks += 1 }
        do { _ = try await client.resolve(mediaType:"movie",id:550,season:nil,episode:nil,serverID:"fake"); fatalError("fake server accepted") }
        catch AetherStreamError.unsupportedServer { checks += 1 }
        let ly = try AetherStreamClient.decodeLy(Data(#"{"proxyHeaders":{"Referer":"https://vidly.pro/movie/354912"},"stream":"https://cdn.example/a.m3u8","sources":[{"url":"https://cdn.example/a.m3u8"},{"url":"https://cdn.example/b.m3u8"}],"subtitles":[{"file":"https://cdn.example/en.vtt","label":"English"}]}"#.utf8))
        check(ly.variants.count == 2 && ly.serverID == "ly", "Ly exact upstream URL fields and deduplication")
        check(ly.variants[0].headers["Origin"] == "https://vidly.pro", "Ly media origin preserved")
        check(ly.variants[0].headers["Referer"] == "https://vidly.pro/movie/354912", "Ly upstream proxyHeaders preserved for native requests")
        check(ly.captions.first?.language == "en", "Ly captions normalize for native selection")
        let fallback = AetherStreamClient(transport: { request in
            let body = request.url!.host == "ly.raccoonunbutteredbagel.zip" ? #"{"stream":"https://cdn.example/coco.m3u8"}"# : "null"
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode:200, httpVersion:nil, headerFields:nil)!)
        })
        let recovered = try await fallback.resolve(mediaType:"movie",id:354912,season:nil,episode:nil)
        check(recovered.serverID == "ly", "Aether ranked sources fall through to Ly")
        do { _ = try await fallback.resolve(mediaType:"movie",id:354912,season:nil,episode:nil,serverID:"vidlink"); fatalError("manual choice silently switched") }
        catch AetherStreamError.invalidResponse { checks += 1 }
        let routes = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath:"Tests/Fixtures/aether-native-routes.json"))) as! [String:[String:String]]
        for (server,kinds) in routes {
            for (kind,expected) in kinds {
                let contract = AetherStreamClient.contracts[server]!
                let template = kind == "movie" ? contract.movie : contract.tv
                let actual = template.replacingOccurrences(of:"{id}",with:kind == "movie" ? "354912" : "1399").replacingOccurrences(of:"{season}",with:"1").replacingOccurrences(of:"{episode}",with:"1")
                check(actual == expected,"native route matches captured Aether request: " + server + " " + kind)
            }
        }
        check(Array(AetherStreamClient.servers.prefix(4)).map(\.id) == ["lul", "nebula", "lil", "ly"], "Aether default ranked source order")
        check(AetherStreamClient.servers.count == 22, "all 22 active Aether sources are represented")
        for server in AetherStreamClient.servers where server.id != "vidlink" && server.id != "animetsu" {
            let client = AetherStreamClient(transport: { request in
                let body: String
                if request.url!.path.hasSuffix("/servers") { body = #"{"servers":[{"name":"secondary"}]}"# }
                else { body = #"{"status":200,"stream":"https://cdn.example/test.m3u8","url":"https://cdn.example/test.m3u8","streams":[{"host":"vidzy","url":"https://cdn.example/test.m3u8"}],"subtitles":[{"file":"https://cdn.example/en.vtt","label":"English"}]}"# }
                return (Data(body.utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
            })
            let result = try await client.resolve(mediaType:server.id == "poyraz" ? "tv" : "movie", id:354912, season:1,episode:1,serverID:server.id)
            check(result.serverID == server.id && !result.variants.isEmpty, "native adapter resolves " + server.id)
        }
        let anime = AetherStreamClient(transport: { request in
            let host = request.url!.host!
            let body: String
            if host == "api.themoviedb.org" { body = #"{"name":"One Piece","first_air_date":"1999-10-20"}"# }
            else if host == "graphql.anilist.co" { body = #"{"data":{"Page":{"media":[{"id":21,"seasonYear":1999,"title":{"english":"One Piece"}}]}}}"# }
            else {
                check(request.url!.query!.contains("id=21") && request.url!.query!.contains("num=1"), "Animetsu resolves confirmed AniList ID and episode")
                check(request.value(forHTTPHeaderField:"Authorization") == nil && !request.url!.absoluteString.contains("api_key"), "TMDB credential does not reach anime backend")
                body = #"{"sources":[{"url":"https://cdn.example/anime.m3u8"}]}"#
            }
            return (Data(body.utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        },metadataCredential:{String(repeating:"a",count:32)})
        let animeResult = try await anime.resolve(mediaType:"tv",id:37854,season:1,episode:1,serverID:"animetsu")
        check(animeResult.serverID == "animetsu", "Animetsu native metadata and embed sequence")
        print("PASS: \(checks) native Aether stream/token/transport checks")
    }
}

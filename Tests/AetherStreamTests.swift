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
        let resolved = try await client.resolve(mediaType:"movie",id:550,season:nil,episode:nil)
        check(resolved == decoded, "native transport result")
        let denied = AetherStreamClient(transport:{ request in
            (Data(),HTTPURLResponse(url:request.url!,statusCode:403,httpVersion:nil,headerFields:nil)!)
        })
        do { _ = try await denied.resolve(mediaType:"movie",id:550,season:nil,episode:nil); fatalError("HTTP failure accepted") }
        catch AetherStreamError.rejected(403) { checks += 1 }
        do { _ = try await client.resolve(mediaType:"movie",id:550,season:nil,episode:nil,serverID:"fake"); fatalError("fake server accepted") }
        catch AetherStreamError.unsupportedServer { checks += 1 }
        print("PASS: \(checks) native Aether stream/token/transport checks")
    }
}

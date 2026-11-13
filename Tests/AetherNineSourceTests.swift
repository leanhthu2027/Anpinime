import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main struct AetherNineSourceTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        count += 1; guard condition() else { fatalError(message) }
    }
    static func main() async throws {
        let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath:"Tests/Fixtures/aether-nine-sources.json"))) as! [String:[String:Any]]
        let expected = ["lul","lil","ly","meridian","rock","polaris","aurora","tiki","vidfast","vidlink"]
        check(AetherStreamClient.primaryServers.map(\.id) == expected, "nine source families keep default relative rank; Tik/Tiki have two endpoints")
        let lil = try AetherStreamClient.decodeAdditional(fixtures["lil"]!,server:"lil",headers:[:])
        check(lil.variants.count == 1 && lil.variants[0].url.path.contains("root-stream-url"), "real Lil nested stream URL is not dropped")
        let meridian = try AetherStreamClient.decodeAdditional(fixtures["meridian"]!,server:"meridian",headers:[:])
        check(meridian.captions.count > 10, "Meridian native VTT list survives decoding")
        check(meridian.variants[0].headers["Referer"] == "https://cdn.example/", "Meridian derives CDN request context")
        let tik = try AetherStreamClient.decodeAdditional(fixtures["aurora"]!,server:"aurora",headers:AetherStreamClient.contracts["aurora"]!.headers)
        check(!tik.variants.isEmpty && tik.variants.allSatisfy(\.requiresRelay), "Tik stream array uses PNG normalization")
        let tiki = try AetherStreamClient.decodeAdditional(["stream":"https://cdn.example/tiki.m3u8"],server:"tiki",headers:[:])
        check(tiki.variants[0].requiresRelay, "Tiki permits the same segment envelope without changing plain TS")
        let fast = try AetherStreamClient.decodeAdditional(fixtures["fast"]!,server:"vidfast",headers:[:])
        check(fast.variants.count == 1 && fast.fallbackVariants.count == 1, "Fast preserves direct transport without presenting it as a quality")
        let direct = fast.fallbackVariants.first { $0.url.host == "cdn.example" }!
        check(direct.headers["Referer"] == "https://vidup.to/" && direct.headers["Origin"] == "https://vidup.to", "Fast uses API referer, not guessed vidcore header")
        check(fast.variants.first { $0.url.host != "cdn.example" }!.headers["Referer"] == nil, "CDN headers do not leak to outer proxy request")
        var noRef = fixtures["fast"]!; noRef["noReferrer"] = true
        let anonymous = try AetherStreamClient.decodeAdditional(noRef,server:"vidfast",headers:[:])
        check((anonymous.variants + anonymous.fallbackVariants).allSatisfy { $0.headers["Referer"] == nil && $0.headers["Origin"] == nil }, "Fast noReferrer is respected")
        let proxyClient = AetherStreamClient(pageOrigin:URL(string:"https://aether.st/")!)
        let wrapped = proxyClient.withMediaFallbacks(fast)
        check(wrapped.variants[0].headers["Referer"] == "https://aether.st/", "existing Fast proxy gets page context")
        let directOnly = AetherStreamClient(transport: { request in
            let good = request.url!.host == "cdn.example"
            return (Data((good ? "#EXTM3U\n#EXTINF:6,\nseg.ts\n" : "blocked").utf8),
                    HTTPURLResponse(url:request.url!,statusCode:good ? 200 : 403,httpVersion:nil,headerFields:nil)!)
        })
        let recoveredDirect = try await directOnly.playable(wrapped)
        check(recoveredDirect.variants.count == 1 && recoveredDirect.variants[0].id == "auto", "direct Fast fallback keeps native adaptive quality controls")
        check(wrapped.fallbackVariants.allSatisfy {
            let target = URLComponents(url:$0.url,resolvingAgainstBaseURL:false)?.queryItems?.first { $0.name == "url" }?.value ?? ""
            return !target.contains("raccoonunbutteredbagel.zip/m3u8-proxy")
        }, "existing proxy URLs are not wrapped in a second proxy")
        let mp4 = try AetherStreamClient.decode(JSONSerialization.data(withJSONObject:fixtures["vidlink"]!))
        check(!mp4.variants.isEmpty, "actual VidLink file payload remains supported")
        let mpd = Data(#"<?xml version="1.0"?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011"><Period><AdaptationSet><Representation id="v"/></AdaptationSet></Period></MPD>"#.utf8)
        check(AetherStreamClient.isMediaPrefix(mpd), "clear DASH is playable alongside HLS and MP4")
        check(!AetherStreamClient.isMediaPrefix(Data("<html><MPD/></html>".utf8)), "HTML mentioning MPD is not DASH")
        check(!AetherStreamClient.isMediaPrefix(Data("<MPD>broken".utf8)), "malformed MPD is not accepted")
        check(!AetherStreamClient.isMediaPrefix(Data("<MPD><Period><ContentProtection/></Period></MPD>".utf8)), "protected DASH is not advertised as supported")
        // Protocol fixture, not a claimed live DASH capture. Upstream currently
        // returned MP4 for the titles we inspected, despite the Android report.
        let signed = Data(#"{"stream":{"type":"dash","playlist":"https://cdn.example/manifest.mpd","headers":{"Cookie":"CloudFront-Policy=test; CloudFront-Signature=test","Origin":"https://vidlink.pro"}}}"#.utf8)
        let signedClient = AetherStreamClient(transport:{ request in
            let body: Data
            if request.url!.host == "vidlink.pro" { body = signed }
            else {
                check(request.value(forHTTPHeaderField:"Cookie") == "CloudFront-Policy=test; CloudFront-Signature=test", "signed CDN cookies reach the native DASH probe")
                body = mpd
            }
            return (body,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        })
        let dash = try await signedClient.resolve(mediaType:"movie",id:550,season:nil,episode:nil,serverID:"vidlink")
        check(dash.variants[0].headers["Cookie"] != nil, "signed cookies survive to MPV playback")
        let hls = Data("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nseg.ts\n#EXT-X-ENDLIST\n".utf8)
        let mediaClient = AetherStreamClient(transport: { request in
            (hls,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"text/html"])!)
        })
        _ = try await mediaClient.playable(meridian)
        check(true, "Meridian playlist with text/html MIME is checked by content")
        var visited = [String]()
        let fastClient = AetherStreamClient(transport: { request in
            let url = request.url!;let body: Data
            if url.path.hasSuffix("/servers") { body = Data(#"{"servers":[{"name":"Euro"},{"name":"Zenith"},{"name":"Prime"}]}"#.utf8) }
            else if url.host == "vfast.raccoonunbutteredbagel.zip" {
                let option = URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems![0].value!
                visited.append(option)
                if option == "Euro" { return (Data(),HTTPURLResponse(url:url,statusCode:503,httpVersion:nil,headerFields:nil)!) }
                body = Data(#"{"url":"https://cdn.example/fast.m3u8","referer":"https://vidup.to/","actualServer":"Zenith","tracks":[{"file":"https://cdn.example/en.vtt","label":"English"}]}"#.utf8)
            } else { body = hls }
            return (body,HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:nil)!)
        })
        let automatic = try await fastClient.resolve(mediaType:"movie",id:238,season:nil,episode:nil,serverID:"vidfast")
        check(visited == ["Euro","Zenith"], "Fast advances through returned server order")
        check(automatic.serverOption == "Zenith" && automatic.serverOptions.map(\.id) == ["Euro","Zenith","Prime"], "validated Fast result retains discovered choices")
        check(automatic.captions.count == 1, "Fast subtitle tracks survive transport validation")
        visited = []
        let manual = try await fastClient.resolve(mediaType:"movie",id:238,season:nil,episode:nil,serverID:"vidfast",serverOption:"Prime")
        check(visited == ["Prime"] && manual.serverOption == "Prime" && manual.actualServerOption == "Zenith", "manual server request and upstream substitution remain distinguishable")
        visited = []
        do { _ = try await fastClient.resolve(mediaType:"movie",id:238,season:nil,episode:nil,serverID:"vidfast",serverOption:"Euro"); fatalError("manual failed server silently switched") }
        catch AetherStreamError.rejected(503) { check(visited == ["Euro"], "manual error does not silently select another server") }
        visited = []
        _ = try await fastClient.resolve(mediaType:"movie",id:238,season:nil,episode:nil,serverID:"vidfast",excludingOptions:["Euro","Zenith"])
        check(visited == ["Prime"], "decoder recovery skips failed Fast servers")
        var requests = [String]()
        let missing = AetherStreamClient(transport: { request in
            requests.append(request.url!.host!)
            return (Data(),HTTPURLResponse(url:request.url!,statusCode:404,httpVersion:nil,headerFields:nil)!)
        })
        do { _ = try await missing.resolve(mediaType:"movie",id:123456789,season:nil,episode:nil); fatalError("missing movie returned stream") }
        catch AetherStreamError.rejected(404) { check(requests.count == 10 && requests.last == "vidlink.pro", "all nine families tried once for a missing movie") }
        print("PASS: \(count) source-specific checks for nine Aether families")
    }
}

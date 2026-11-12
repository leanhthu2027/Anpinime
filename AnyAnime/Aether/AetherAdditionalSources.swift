import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension AetherStreamClient {
    struct SourceContract { let movie: String; let tv: String; let headers: [String:String] }
    static let contracts: [String:SourceContract] = [
        "lul": .init(movie: "https://lul.raccoonunbutteredbagel.zip/movie/{id}", tv: "https://lul.raccoonunbutteredbagel.zip/tv/{id}/{season}/{episode}", headers: [:]),
        "nebula": .init(movie: "https://filler.raccoonunbutteredbagel.zip/movie/{id}", tv: "https://filler.raccoonunbutteredbagel.zip/tv/{id}/{season}/{episode}", headers: [:]),
        "lil": .init(movie: "https://lil.raccoonunbutteredbagel.zip/movie/{id}", tv: "https://lil.raccoonunbutteredbagel.zip/show/{id}/{season}/{episode}", headers: [:]),
        "ly": .init(movie: "https://ly.raccoonunbutteredbagel.zip/movie/{id}", tv: "https://ly.raccoonunbutteredbagel.zip/tv/{id}/{season}/{episode}", headers: ["Origin": "https://vidly.pro", "Referer": "https://vidly.pro/"]),
        "meridian": .init(movie: "https://meridian.raccoonunbutteredbagel.zip/movie/{id}", tv: "https://meridian.raccoonunbutteredbagel.zip/show/{id}/{season}/{episode}", headers: [:]),
        "rock": .init(movie: "https://rock.raccoonunbutteredbagel.zip/movie/{id}", tv: "https://rock.raccoonunbutteredbagel.zip/tv/{id}/{season}/{episode}", headers: ["Origin": "https://vidrock.to", "Referer": "https://vidrock.to"]),
        "polaris": .init(movie: "https://shore.raccoonunbutteredbagel.zip/movie/{id}", tv: "https://shore.raccoonunbutteredbagel.zip/show/{id}?s={season}&e={episode}", headers: [:]),
        "aurora": .init(movie: "https://tik.raccoonunbutteredbagel.zip/movie/{id}", tv: "https://tik.raccoonunbutteredbagel.zip/tv/{id}/{season}/{episode}", headers: ["Origin": "https://play.xpass.top", "Referer": "https://play.xpass.top"]),
        "tiki": .init(movie: "https://tiki.raccoonunbutteredbagel.zip/movie/{id}", tv: "https://tiki.raccoonunbutteredbagel.zip/tv/{id}/{season}/{episode}", headers: ["Origin": "https://play.xpass.top", "Referer": "https://play.xpass.top/"]),
        "link": .init(movie: "https://link.raccoonunbutteredbagel.zip/movie/{id}", tv: "https://link.raccoonunbutteredbagel.zip/tv/{id}/{season}/{episode}", headers: ["Origin": "https://nextgencloudfabric.com", "Referer": "https://nextgencloudfabric.com/"]),
        "vidfast": .init(movie: "https://vfast.raccoonunbutteredbagel.zip/movie/{id}/servers", tv: "https://vfast.raccoonunbutteredbagel.zip/tv/{id}/{season}/{episode}/servers", headers: [:]),
        "vidy": .init(movie: "https://vidy.aether.cx/movie/{id}", tv: "https://vidy.aether.cx/tv/{id}/{season}/{episode}", headers: [:]),
        "aether-subtitulado": .init(movie: "https://le.aether.cx/movie/{id}?lang=sub", tv: "https://le.aether.cx/tv/{id}/{season}/{episode}?lang=sub", headers: [:]),
        "aether-latino": .init(movie: "https://le.aether.cx/movie/{id}?lang=lat", tv: "https://le.aether.cx/tv/{id}/{season}/{episode}?lang=lat", headers: [:]),
        "aether-castellano": .init(movie: "https://le.aether.cx/movie/{id}?lang=esp", tv: "https://le.aether.cx/tv/{id}/{season}/{episode}?lang=esp", headers: [:]),
        "vine": .init(movie: "https://vine.aether.cx/movie/{id}", tv: "https://vine.aether.cx/tv/{id}/{season}/{episode}", headers: [:]),
        "gallic": .init(movie: "https://api.subl2cw8mg.workers.dev/movie/{id}", tv: "", headers: [:]),
        "baguette": .init(movie: "https://baguette.aether.cx/api/movie/{id}", tv: "https://baguette.aether.cx/api/tv/{id}?s={season}&e={episode}", headers: [:]),
        "poyraz": .init(movie: "", tv: "https://zephyr-quill-83f2a.subrujplax.workers.dev/tv/{id}/{season}/{episode}", headers: [:]),
        "yildiz": .init(movie: "https://yildiz.aether.cx/movie/{id}", tv: "https://yildiz.aether.cx/tv/{id}/{season}/{episode}", headers: [:]),
    ]
}

extension AetherStreamClient {
    static func supports(_ id: String, mediaType: String) -> Bool {
        if id == "vidlink" { return true }
        if id == "animetsu" { return mediaType == "tv" }
        guard let item = contracts[id] else { return false }
        return !(mediaType == "movie" ? item.movie : item.tv).isEmpty
    }
    func json(_ url: URL, headers: [String:String] = [:], body: Data? = nil) async throws -> [String:Any] {
        try Task.checkCancellation()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 12
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let body { request.httpMethod = "POST"; request.httpBody = body; request.setValue("application/json", forHTTPHeaderField:"Content-Type") }
        let (data,response) = try await transport(request)
        try Task.checkCancellation()
        guard response.statusCode == 200 else { throw AetherStreamError.rejected(response.statusCode) }
        guard data.count <= 4 * 1024 * 1024, let object = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else { throw AetherStreamError.invalidResponse }
        return object
    }
    func resolveAdditional(_ server: String, mediaType: String, id: Int, season: Int?, episode: Int?) async throws -> AetherStream {
        _ = try Self.requestURL(mediaType:mediaType,id:id,season:season,episode:episode,now:Date())
        if server == "animetsu" { return try await resolveAnimetsu(mediaType:mediaType,id:id,season:season,episode:episode) }
        guard let config = Self.contracts[server] else { throw AetherStreamError.unsupportedServer }
        let template = mediaType == "movie" ? config.movie : config.tv
        guard !template.isEmpty else { throw AetherStreamError.noStreams }
        let route = template.replacingOccurrences(of:"{id}",with:String(id)).replacingOccurrences(of:"{season}",with:String(season ?? 0)).replacingOccurrences(of:"{episode}",with:String(episode ?? 0))
        guard let url = Self.safeURL(route) else { throw AetherStreamError.invalidMedia }
        let object = try await json(url)
        if server == "vidfast" {
            let rows = object["servers"] as? [[String:Any]] ?? []
            for row in rows.prefix(12) {
                try Task.checkCancellation()
                guard let name = row["name"] as? String else { continue }
                var parts = URLComponents(url:url.deletingLastPathComponent(),resolvingAgainstBaseURL:false)!
                parts.queryItems = [.init(name:"server",value:name)]
                do {
                    let value = try await json(parts.url!)
                    return try Self.decodeAdditional(value,server:server,headers:[:])
                } catch { try Task.checkCancellation() }
            }
            throw AetherStreamError.noStreams
        }
        return try Self.decodeAdditional(object,server:server,headers:config.headers)
    }
    static func decodeAdditional(_ object: [String:Any], server: String, headers: [String:String]) throws -> AetherStream {
        guard object["error"] as? Bool != true, (object["error"] as? String)?.isEmpty != false, object["success"] as? Bool != false else { throw AetherStreamError.noStreams }
        if server.hasPrefix("aether-"), (object["status"] as? Int) != 200 { throw AetherStreamError.noStreams }
        var candidates = [String]()
        for key in ["stream","stream_url","url"] { if let value = object[key] as? String { candidates.append(value) } }
        var rows = (object["streams"] as? [[String:Any]] ?? []) + (object["sources"] as? [[String:Any]] ?? [])
        if server == "baguette" { rows = rows.filter { ($0["host"] as? String)?.lowercased() == "vidzy" } }
        candidates += rows.compactMap { $0["url"] as? String }
        candidates += object["streams"] as? [String] ?? []
        var seen = Set<URL>()
        let media = candidates.compactMap(Self.safeURL).filter { seen.insert($0).inserted }
        guard !media.isEmpty else { throw AetherStreamError.noStreams }
        var mediaHeaders = headers
        mediaHeaders.merge(Self.cleanHeaders(object["proxyHeaders"])) { _,new in new }
        if ["meridian","yildiz"].contains(server), let first = media.first, let host = first.host {
            mediaHeaders["Origin"] = "https://" + host; mediaHeaders["Referer"] = "https://" + host + "/"
        }
        let captions = (object["subtitles"] ?? object["subs"] ?? object["tracks"]) as? [[String:Any]] ?? []
        let normalized: [[String:Any]] = captions.compactMap { row in
            guard let url = (row["url"] ?? row["file"]) as? String else { return nil }
            return ["id":url,"url":url,"language":(row["language"] ?? row["label"] ?? row["lang"]) as? String ?? "und", "type":url.lowercased().contains(".srt") ? "srt" : "vtt"]
        }
        let captionData = try JSONSerialization.data(withJSONObject:["stream":["type":"hls","playlist":media[0].absoluteString,"captions":normalized]])
        let parsed = try Self.decode(captionData,serverID:server)
        let variants = media.enumerated().map { index,url in
            AetherMediaVariant(id:index == 0 ? "auto" : server + "-\(index)",label:"Luồng \(index + 1)",url:url,headers:mediaHeaders)
        }
        return AetherStream(serverID:server,variants:variants,captions:parsed.captions)
    }
    private func resolveAnimetsu(mediaType: String, id: Int, season: Int?, episode: Int?) async throws -> AetherStream {
        guard mediaType == "tv", let episode else { throw AetherStreamError.noStreams }
        guard let credential = metadataCredential() else { throw AetherStreamError.noStreams }
        var components = URLComponents(string:"https://api.themoviedb.org/3/tv/\(id)")!
        components.queryItems = [.init(name:"language",value:"en-US")]
        var metadataHeaders = [String:String]()
        if credential.range(of:"^[a-fA-F0-9]{32}$",options:.regularExpression) != nil { components.queryItems?.append(.init(name:"api_key",value:credential)) }
        else { metadataHeaders["Authorization"] = "Bearer " + credential }
        let metadata = try await json(components.url!,headers:metadataHeaders)
        guard let title = metadata["name"] as? String else { throw AetherStreamError.noStreams }
        let year = Int(String((metadata["first_air_date"] as? String ?? "").prefix(4)))
        let query = "query ($search: String, $type: MediaType) { Page(page: 1, perPage: 20) { media(search: $search, type: $type, sort: POPULARITY_DESC) { id type format seasonYear title { romaji english native } } } }"
        let body = try JSONSerialization.data(withJSONObject:["query":query,"variables":["search":title,"type":"ANIME"]])
        let list = try await json(URL(string:"https://graphql.anilist.co")!,body:body)
        let data = list["data"] as? [String:Any], page = data?["Page"] as? [String:Any]
        let matches = (page?["media"] as? [[String:Any]] ?? []).filter { row in
            let titles = row["title"] as? [String:String] ?? [:]
            return titles.values.contains { $0.compare(title,options:[.caseInsensitive,.diacriticInsensitive]) == .orderedSame }
                && (year == nil || row["seasonYear"] as? Int == year)
        }
        // Fail explicitly on ambiguous mapping; never play a different anime.
        guard matches.count == 1, let animeID = matches.first?["id"] as? Int else { throw AetherStreamError.noStreams }
        let headers = ["Referer":"https://animetsu.to/","Origin":"https://backend.animetsu.to","Accept":"application/json, text/plain, */*","User-Agent":"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"]
        for name in ["pahe","zoro","zaza","meg","bato"] {
            var parts = URLComponents(string:"https://backend.animetsu.to/api/anime/tiddies")!
            parts.queryItems = [.init(name:"server",value:name),.init(name:"id",value:String(animeID)),.init(name:"num",value:String(episode)),.init(name:"subType",value:"dub")]
            do { return try Self.decodeAdditional(try await json(parts.url!,headers:headers),server:"animetsu",headers:headers) }
            catch { try Task.checkCancellation() }
        }
        throw AetherStreamError.noStreams
    }
}

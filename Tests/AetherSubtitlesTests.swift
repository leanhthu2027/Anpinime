import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class SubtitleProtocol: URLProtocol {
    static let lock = NSLock()
    private static var requests: [URLRequest] = []
    static var captured: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    static var translationFailure = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); Self.lock.unlock()
        let url = request.url!
        let data: Data
        var status = 200
        if url.host == "translate.googleapis.com" {
            if Self.translationFailure { status = 503; data = Data() }
            else {
                let source = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "q" }!.value!
                let result = source.replacingOccurrences(of: "Hello", with: "Xin chào").replacingOccurrences(of: "Goodbye", with: "Tạm biệt")
                data = try! JSONSerialization.data(withJSONObject: ["sentences": [["trans": result]]])
            }
        } else if url.host == "sub.vdrk.site" {
            data = Data(#"[{"file":"https://captions.example/en.srt","label":"English1"},{"file":"https://captions.example/vi.srt","label":"Vietnamese"}]"#.utf8)
        } else if url.host == "rest.opensubtitles.org" {
            data = Data(#"[{"SubDownloadLink":"https://captions.example/download/english.gz","LanguageName":"English","ISO639":"en"}]"#.utf8)
        } else if url.path == "/bad.srt" { data = Data("<html>Access denied</html>".utf8) }
        else { data = Data("1\n00:00:01,000 --> 00:00:03,500\nHello\nworld\n\n2\n00:00:05,000 --> 00:00:06,000\nGoodbye\n".utf8) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main struct AetherSubtitlesTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError("FAIL: " + message) }
        checks += 1; print("PASS: " + message)
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aether-subtests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SubtitleProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = AetherSubtitleClient(session: session, cacheDirectory: root)
        let indexes = try JSONSerialization.data(withJSONObject: [
            ["file": "https://example.com/en.srt", "label": "English Hi"],
            ["file": "https://example.com/vi.vtt", "label": "Vietnamese2"],
            ["file": "http://example.com/unsafe.srt", "label": "English"],
            ["file": "https://localhost/private.srt", "label": "English"]])
        let decoded = AetherSubtitleClient.decodeIndex(indexes, source: "nova")
        check(decoded.count == 2, "external index ignores insecure and local file destinations")
        check(AetherSubtitleClient.languageCode("Vietnamese2") == "vi", "numbered Vietnamese labels retain preferred language")
        check(AetherSubtitleClient.languageCode("English Hi") == "en", "hearing impaired English label maps to language")
        check(AetherSubtitleClient.languageCode("vi-VN") == "vi", "language-region track matches Vietnamese preference")
        let remote = await client.external(mediaType: "movie", id: 550, imdbID: "tt0137523")
        check(remote.count == 3 && remote.first?.language == "vi", "external sources merge with Vietnamese first")
        let legacy = SubtitleProtocol.captured.first { $0.url?.host == "rest.opensubtitles.org" }
        check(legacy?.url?.path == "/search/imdbid-0137523" && legacy?.value(forHTTPHeaderField: "X-User-Agent") == "VLSub 0.10.2", "uses exact Aether legacy index contract")
        check(remote.contains { $0.url.path == "/download/subencoding-utf8/english" }, "OpenSubtitles uses Aether uncompressed UTF8 download route")
        _ = await client.external(mediaType: "tv", id: 1399, season: 0, episode: 1, imdbID: "tt0944947")
        check(SubtitleProtocol.captured.contains { $0.url?.path == "/v1/tv/1399/0/1" }, "TV subtitles include specials season zero without switching to movie")
        check(SubtitleProtocol.captured.contains { $0.url?.path == "/search/episode-1/imdbid-0944947/season-0" }, "TV OpenSubtitles keys use exact season and episode")
        let english = AetherSubtitle(title: "English", language: "en", url: URL(string: "https://captions.example/en.srt")!, headers: ["Referer": "https://aether.st/", "Origin": "https://aether.st", "Cookie": "must-not-leak", "Authorization": "must-not-leak", "User-Agent": "bad\r\nheader"])
        let file = try await client.materialize(english)
        let captionRequest = SubtitleProtocol.captured.last!
        check(captionRequest.value(forHTTPHeaderField: "Referer") == "https://aether.st/" && captionRequest.value(forHTTPHeaderField: "Origin") == "https://aether.st", "provider caption referer and origin reach subtitle transport")
        check(captionRequest.value(forHTTPHeaderField: "Cookie") == nil && captionRequest.value(forHTTPHeaderField: "Authorization") == nil && captionRequest.value(forHTTPHeaderField: "User-Agent") == nil, "caption transport rejects sensitive and CRLF injected headers")
        check(file.pathExtension == "srt" && FileManager.default.fileExists(atPath: file.path), "download writes parsed text subtitle into local cache")
        let before = SubtitleProtocol.captured.count
        _ = try await client.materialize(english)
        check(SubtitleProtocol.captured.count == before, "valid local subtitle cache avoids a second remote request")
        let translated = try await client.translateToVietnamese(file)
        let output = try String(contentsOf: translated, encoding: .utf8)
        check(output.contains("Xin chào") && output.contains("Tạm biệt"), "translation returns actual service text for each cue")
        check(output.contains("00:00:01,000 --> 00:00:03,500") && output.contains("00:00:05,000 --> 00:00:06,000"), "translation preserves exact cue timestamps")
        check(AetherSubtitleClient.cues(output).count == 2, "batch translation preserves cue alignment including multiline text")
        let translation = SubtitleProtocol.captured.first { $0.url?.host == "translate.googleapis.com" }
        let query = URLComponents(url: translation!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        check(query.contains { $0.name == "tl" && $0.value == "vi" } && query.contains { $0.name == "client" && $0.value == "gtx" }, "native translation uses same provider and Vietnamese target as Aether")
        let vtt = root.appendingPathComponent("sample.vtt")
        try Data("WEBVTT\n\ncue-one\n00:01.000 --> 00:03.000 align:start position:10%\nHello\n".utf8).write(to: vtt)
        let translatedVTT = try await client.translateToVietnamese(vtt)
        let resultVTT = try String(contentsOf: translatedVTT, encoding: .utf8)
        check(resultVTT.hasPrefix("WEBVTT\n") && resultVTT.contains("cue-one\n00:01.000 --> 00:03.000 align:start position:10%"), "VTT identifiers and native rendering settings survive translation")
        do {
            _ = try await client.materialize(AetherSubtitle(title: "bad", language: "en", url: URL(string: "https://captions.example/bad.srt")!))
            fatalError("FAIL: rejected HTML")
        } catch AetherSubtitleError.invalidFormat { check(true, "HTML error response cannot become a selectable subtitle file") }
        let failingFile = root.appendingPathComponent("failure.srt")
        try Data("1\n00:00:00,000 --> 00:00:01,000\nHello\n".utf8).write(to: failingFile)
        SubtitleProtocol.translationFailure = true
        do { _ = try await client.translateToVietnamese(failingFile); fatalError("FAIL: service failure") }
        catch AetherSubtitleError.translationFailed {
            check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("failure.vi.srt").path), "translation failure never publishes a partial subtitle")
            let originalAfterFailure = try String(contentsOf: failingFile, encoding: .utf8)
            check(originalAfterFailure.contains("Hello"), "translation failure preserves original subtitle")
        }
        let countBeforeInvalid = SubtitleProtocol.captured.count
        let invalid = await client.external(mediaType: "tv", id: 1399, season: nil, episode: 1)
        check(invalid.isEmpty && SubtitleProtocol.captured.count == countBeforeInvalid, "invalid TV identity issues no movie fallback request")
        print("PASS: Aether subtitle tests \(checks)")
    }
}

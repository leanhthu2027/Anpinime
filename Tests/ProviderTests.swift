import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
final class ProviderProtocol: URLProtocol {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var failingHost: String?
    static func reset(failing: String? = nil) { lock.lock(); defer { lock.unlock() }; requests=[]; failingHost=failing }
    static func captured() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); let failing=Self.failingHost; Self.lock.unlock()
        let url=request.url!, host=url.host!, path=url.path
        var status=200
        let body: Any
        var html: String?
        if host == failing { status=503; body=["error":"Unavailable"] }
        else if host == "kkphim.com" { html=try! String(contentsOfFile:"Tests/Fixtures/kkphim-ongoing.html",encoding:.utf8); body=[:] }
        else if path == "/the-loai" || path == "/quoc-gia" { body=["items":[["slug":"own-taxonomy","name":"Own category"]]] }
        else if path.hasPrefix("/phim/") || path.hasPrefix("/api/film/") {
            body=["movie":["name":host],"episodes":[["server_name":"Vietsub","server_data":[["name":"01","slug":"tap-1","link_m3u8":"https://"+host+"/movie.m3u8","link_embed":"https://"+host+"/advertising-player"]]]]]
        } else { body=["items":[["slug":"shared-slug","name":host]]] }
        let data=html.map{Data($0.utf8)} ?? (try! JSONSerialization.data(withJSONObject:body))
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self)
    }
}
enum AnimeService { static let userAgent = "AnPinime Provider Tests" }
@main struct ProviderTests {
    @MainActor static func main() async throws {
        try await verifyTransportPolicy()
        let config=URLSessionConfiguration.ephemeral; config.protocolClasses=[ProviderProtocol.self]
        let session=URLSession(configuration:config)
        defer { session.invalidateAndCancel() }
        for (source, host, category) in [(ContentSource.film4k, "phim.nguonc.com", "api/films/the-loai/hanh-dong"),
                                         (.kkphim, "phimapi.com", "v1/api/the-loai/hanh-dong")] {
            ProviderProtocol.reset()
            let provider = MovieProvider(source: source, session: session)
            let sections = try await provider.home()
            let search = try await provider.search("Tên phim & dấu tiếng Việt")
            let list = try await provider.list(path: category, page: 2)
            let detail = try await provider.detail(search[0])
            let playback = try await provider.resolve(detail.episodes[0])
            require(sections.flatMap(\.items).allSatisfy { $0.source == source } && list.allSatisfy { $0.source == source }, "Catalog identity follows " + source.rawValue)
            require(Set(ProviderProtocol.captured().compactMap { $0.url?.host }) == [host], "Home/search/category/detail/playback only request " + host)
            require(playback.url.host == host && playback.url.path == "/movie.m3u8" && playback.webURL == nil, "Native content never falls back to an advertising page")
            let searchRequest = ProviderProtocol.captured().first { $0.url!.path.contains("search") || $0.url!.path.contains("tim-kiem") }!
            require(URLComponents(url: searchRequest.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "keyword" })?.value == "Tên phim & dấu tiếng Việt", "Search keyword remains intact")
            if source == .kkphim {
                require(provider.categories.contains { $0.path == "v1/api/the-loai/own-taxonomy" }, "KKPhim refreshes its taxonomy from its own API")
                ProviderProtocol.reset()
                let ongoing = try await provider.list(path: "site/danh-sach/phim-bo-dang-chieu", page: 2)
                require(ongoing.count == 2 && ongoing.allSatisfy { $0.source == .kkphim && $0.url.host == "phimapi.com" }, "KKPhim website-only lists retain provider identity")
                let website = ProviderProtocol.captured().first!.url!
                require(website.host == "kkphim.com" && website.path == "/danh-sach/phim-bo-dang-chieu" && website.query == "page=2", "Ongoing list paginates on KKPhim's actual website route")
                _ = try await provider.detail(ongoing[0])
                require(ProviderProtocol.captured().last!.url!.host == "phimapi.com", "Website results open details through the same provider's API")
            }
            ProviderProtocol.reset(failing: host)
            provider.invalidate()
            do { _ = try await provider.search("fail"); fatalError("Expected source failure") } catch {}
            require(Set(ProviderProtocol.captured().compactMap { $0.url?.host }) == [host], "Failure never switches providers")
        }
        print("Public provider regressions passed")
    }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
        print("PASS: " + message)
    }

    @MainActor static func verifyTransportPolicy() async throws {
        let core = URL(string: "https://core.example")!
        require(Phim4KTransportPolicy.sameOrigin(core, URL(string: "https://CORE.example:443/rest-api/v130/movies")!), "Core origin compares case-insensitive host and effective HTTPS port")
        for changed in ["http://core.example", "https://core.example:8443", "https://core.example.attacker.test", "https://other.example", "https://user:password@core.example"] {
            let url = URL(string: changed)!
            require(!Phim4KTransportPolicy.permitsCoreRequest(url, baseURL: core), "Core credentials cannot follow a changed scheme, port, host or userinfo")
        }
        let loopback = URL(string: "http://127.0.0.1:8765")!
        require(!Phim4KTransportPolicy.permitsEndpoint(loopback) && Phim4KTransportPolicy.permitsEndpoint(loopback, allowLoopbackHTTP: true), "HTTP loopback requires an explicit fixture opt-in")
        require(!Phim4KTransportPolicy.permitsEndpoint(URL(string: "http://core.example")!, allowLoopbackHTTP: true), "Fixture opt-in never permits public HTTP endpoints")
        let originalHTTPMedia = URL(string: "http://media.example/movie.model?token=fixture")!
        require(Phim4KTransportPolicy.permitsMediaEndpoint(originalHTTPMedia) && !Phim4KTransportPolicy.permitsEndpoint(originalHTTPMedia), "An original HTTP media URL is allowed only by media policy, never Core or gateway policy")
        require(!Phim4KTransportPolicy.permitsMediaEndpoint(loopback)
                && Phim4KTransportPolicy.permitsMediaEndpoint(loopback, allowLoopbackHTTP: true), "HTTP media loopback still requires an explicit local fixture")
        require(!Phim4KTransportPolicy.permitsEndpoint(URL(string: "file:///movie.mkv")!), "Non-HTTP media/gateway schemes are rejected")
        var signedMedia = URLRequest(url: URL(string: "https://media.example:8443/movie.mkv?token=fixture")!)
        signedMedia.setValue("fixture-key", forHTTPHeaderField: "API-KEY")
        signedMedia.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
        signedMedia.setValue("account=fixture", forHTTPHeaderField: "Cookie")
        signedMedia.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
        signedMedia.setValue("fixture-agent", forHTTPHeaderField: "User-Agent")
        let changedPort = Phim4KTransportPolicy.redirectedRequest(signedMedia, from: URL(string: "https://media.example/movie.mkv")!)!
        require(changedPort.value(forHTTPHeaderField: "API-KEY") == nil && changedPort.value(forHTTPHeaderField: "Authorization") == nil && changedPort.value(forHTTPHeaderField: "Cookie") == nil,
                "A same-host port change is cross-origin and removes sensitive headers")
        require(changedPort.value(forHTTPHeaderField: "Range") == "bytes=0-2047" && changedPort.value(forHTTPHeaderField: "User-Agent") == "fixture-agent", "Cross-origin media redirects preserve only required non-sensitive media headers")
        require(!changedPort.httpShouldHandleCookies && changedPort.url == signedMedia.url, "A redirect cannot reattach session cookies or rewrite the server-supplied signed URL")
        var downgrade = signedMedia
        downgrade.url = loopback
        require(Phim4KTransportPolicy.redirectedRequest(downgrade, from: core, allowLoopbackHTTP: true, allowRemoteHTTP: true) == nil, "HTTPS downgrade is rejected even when HTTP media and loopback fixtures are enabled")
        let upgrade = Phim4KTransportPolicy.redirectedRequest(signedMedia, from: originalHTTPMedia, allowRemoteHTTP: true)
        require(upgrade?.url == signedMedia.url && upgrade?.value(forHTTPHeaderField: "API-KEY") == nil
                && upgrade?.value(forHTTPHeaderField: "Range") == "bytes=0-2047", "An HTTP-to-HTTPS media redirect is allowed while sensitive headers are stripped")

        // Exercise URLSession's real redirect delegate with two local origins.
        // URLProtocol fixtures alone cannot prove redirected header behavior.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", #"""
import json, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
paths = []
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        paths.append(self.path)
        if self.path == '/cross': destination = 'http://127.0.0.1:'+str(second.server_port)+'/headers'
        elif self.path == '/same': destination = '/headers'
        elif self.path.startswith('/loop/'):
            destination = '/loop/'+str(int(self.path.rsplit('/',1)[1])+1)
        else: destination = None
        values = {k:self.headers.get(k) for k in ['API-KEY','Authorization','Cookie','Range','User-Agent']}
        values['fixturePath'] = self.path
        if self.path == '/requests': values['loopPaths'] = [p for p in paths if p.startswith('/loop/')]
        body = json.dumps(values).encode()
        self.send_response(302 if destination else 200)
        if destination: self.send_header('Location',destination)
        self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
first = ThreadingHTTPServer(('127.0.0.1',0),Handler)
second = ThreadingHTTPServer(('127.0.0.1',0),Handler)
for server in [first,second]: threading.Thread(target=server.serve_forever,daemon=True).start()
print(json.dumps([first.server_port,second.server_port]),flush=True)
threading.Event().wait()
"""#]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        var line = Data()
        while line.count < 128 {
            guard let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else { throw URLError(.cannotConnectToHost) }
            if byte == Data([10]) { break }
            line.append(byte)
        }
        let ports = try JSONSerialization.jsonObject(with: line) as! [Int]
        let root = URL(string: "http://127.0.0.1:\(ports[0])")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        let mediaSession = URLSession(configuration: configuration, delegate: Phim4KRedirectPolicy(mode: .media, allowLoopbackHTTP: true, maxRedirects: 2), delegateQueue: nil)
        let coreSession = URLSession(configuration: configuration, delegate: Phim4KRedirectPolicy(mode: .sameOriginOnly, allowLoopbackHTTP: true, maxRedirects: 2), delegateQueue: nil)
        defer { mediaSession.invalidateAndCancel(); coreSession.invalidateAndCancel() }
        var cross = URLRequest(url: root.appendingPathComponent("cross"), timeoutInterval: 5)
        for (name, value) in ["API-KEY": "fixture-key", "Authorization": "Bearer fixture", "Cookie": "account=fixture", "Range": "bytes=0-2047", "User-Agent": "fixture-agent"] { cross.setValue(value, forHTTPHeaderField: name) }
        let (body, response) = try await mediaSession.data(for: cross)
        let received = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        require((response as? HTTPURLResponse)?.statusCode == 200 && response.url?.port == ports[1], "Media session follows an allowed cross-origin loopback redirect")
        require(["API-KEY", "Authorization", "Cookie"].allSatisfy { received[$0] is NSNull }, "Actual cross-origin redirect never sends Core/session credentials to the media origin")
        require(received["Range"] as? String == "bytes=0-2047" && received["User-Agent"] as? String == "fixture-agent", "Actual redirected media request keeps Range and User-Agent")
        let (_, rejected) = try await coreSession.data(for: cross)
        require((rejected as? HTTPURLResponse)?.statusCode == 302 && rejected.url?.port == ports[0], "Core-only session refuses cross-origin redirects before sending its API key")
        cross.url = root.appendingPathComponent("same")
        let (sameBody, sameResponse) = try await coreSession.data(for: cross)
        let sameHeaders = try JSONSerialization.jsonObject(with: sameBody) as! [String: Any]
        require((sameResponse as? HTTPURLResponse)?.statusCode == 200 && sameHeaders["API-KEY"] as? String == "fixture-key", "Same-origin Core redirects retain the required client header")
        for iteration in 0..<2 {
            let (_, bounded) = try await mediaSession.data(from: root.appendingPathComponent("loop/0"))
            // FoundationNetworking may omit a refused 302's body. Verify the
            // actual server-side requests, independently of that client detail.
            let (traceBody, _) = try await mediaSession.data(from: root.appendingPathComponent("requests"))
            let actual = try JSONSerialization.jsonObject(with: traceBody) as! [String: Any]
            let requests = actual["loopPaths"] as? [String] ?? []
            let status = (bounded as? HTTPURLResponse)?.statusCode ?? 0
            let path = bounded.url?.path ?? "missing"
            let current = Array(requests.dropFirst(iteration * 3))
            require(status == 302 && path == "/loop/2" && current == ["/loop/0", "/loop/1", "/loop/2"],
                    "Redirect count is bounded per task and resets for a new request; iteration=\(iteration), status=\(status), responsePath=\(path), serverRequests=\(current)")
        }
    }

}

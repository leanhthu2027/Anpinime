import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class AetherFixture: URLProtocol {
    static let lock = NSLock()
    static var replies: [String: (Int, String, String?)] = [:]
    static var requests: [String] = []
    static func reset(_ replies: [String: (Int, String, String?)]) {
        lock.lock(); defer { lock.unlock() }; self.replies = replies; requests = []
    }
    static var captured: [String] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let host = request.url!.host!
        Self.lock.lock(); Self.requests.append(host); let reply = Self.replies[host]; Self.lock.unlock()
        guard let (status, body, destination) = reply else { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
        let url = destination.flatMap(URL.init(string:)) ?? request.url!
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
}

@main struct AetherDomainResolverTests {
    static var checks = 0
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError("FAIL: " + message) }; checks += 1; print("PASS: " + message)
    }
    static func main() async throws {
        let html = try String(contentsOfFile: "Tests/Fixtures/aether-domains.html", encoding: .utf8)
        require(AetherDomainPolicy.domains(in: html).compactMap(\.host) == ["aether.st", "aether.ist", "aether.cx"], "HTML extraction ignores unsafe links without depending on tables")
        require(AetherDomainPolicy.domains(in: "| Active | [Aether](https://aether.st) |\nhttps://aether.cx\nhttps://aether.st").count == 2, "Markdown/plain links are deduplicated")
        for input in ["http://aether.st", "https://user@aether.st", "https://aether.st.evil.org", "https://aether.st:8443", "https://127.0.0.1", "https://aether.st/path", "https://aether.st?x=y", "javascript:alert(1)", "https://aether.st#fragment", "https://aether.st."] {
            require(AetherDomainPolicy.manualOrigin(input) == nil, "rejects unsafe/non-origin input: " + input)
        }
        require(AetherDomainPolicy.manualOrigin(" HTTPS://AETHER.ST:443/ ") == AetherDomainPolicy.defaultURL, "valid origins canonicalize scheme, case and default port")
        require(AetherDomainPolicy.permitsNavigation(URL(string: "https://aether.st/some/page?q=movie#subtitles")!, pinnedOrigin: AetherDomainPolicy.defaultURL), "website paths, queries and subtitles stay in the pinned session")
        require(!AetherDomainPolicy.permitsNavigation(URL(string: "https://aether.cx/")!, pinnedOrigin: AetherDomainPolicy.defaultURL), "even official mirrors cannot switch a playing session's origin")
        let name = "AnPinime.AetherTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AetherFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let resolver = AetherDomainResolver(session: session, defaultsSuiteName: name)
        AetherFixture.reset(["rentry.co": (200, html, nil), "aether.st": (503, "down", nil), "aether.ist": (200, "<!DOCTYPE html><html><script src='/app.js'></script></html>", nil)])
        let result = try await resolver.resolve()
        require(result.origin.host == "aether.ist", "unavailable preferred seed falls back to a responding verified domain")
        require(AetherFixture.captured == ["rentry.co", "aether.st", "aether.ist"], "bounded discovery/probes stop after the first valid origin")
        let cached = try await resolver.resolve()
        require(cached == result && AetherFixture.captured.count == 3, "TTL caches successful resolution without probing during playback")
        let restored = AetherDomainResolver(session: session, defaultsSuiteName: name)
        AetherFixture.reset(["aether.ist": (200, "<html>App</html>", nil)])
        let restoredResult = try await restored.resolve()
        require(restoredResult.origin == result.origin && AetherFixture.captured == ["aether.ist"], "last working domain persists, is re-probed and official directory TTL survives restart")
        try await resolver.setManualDomain("https://aether.cx")
        AetherFixture.reset(["aether.cx": (503, "down", nil), "aether.st": (200, "<html>App</html>", nil)])
        do { _ = try await resolver.resolve(); fatalError("Manual failure must be reported") } catch AetherError.unavailable {}
        require(AetherFixture.captured == ["aether.cx"], "manual failure does not silently switch domains")
        do { try await resolver.setManualDomain("https://aether.xyz"); fatalError("Unlisted domain must fail") } catch AetherError.invalidDomain {}
        require(defaults.string(forKey: AetherDomainPolicy.manualKey) == "https://aether.cx/", "invalid manual choice preserves previous setting")
        try await resolver.setManualDomain("")
        AetherFixture.reset(["rentry.co": (200, "https://aether.xyz", nil), "aether.xyz": (200, "<html>App</html>", nil)])
        let extended = try await resolver.resolve(force: true)
        require(extended.origin.host == "aether.xyz", "official document can add a policy-compliant origin")
        AetherFixture.reset(["rentry.co": (200, "https://evil.example https://aether.st", "https://evil.example/"), "aether.st": (200, "<html>App</html>", "https://evil.example/")])
        do { _ = try await resolver.resolve(force: true); fatalError("Foreign final URLs must fail") } catch AetherError.unavailable {}
        require(!AetherFixture.captured.contains("evil.example") && AetherFixture.captured.count <= 9, "foreign final responses are never trusted or used as probe destinations")
        let guardDelegate = AetherRedirectGuard(hosts: ["aether.st", "aether.cx"])
        let task = session.dataTask(with: AetherDomainPolicy.defaultURL)
        let response = HTTPURLResponse(url: AetherDomainPolicy.defaultURL, statusCode: 302, httpVersion: nil, headerFields: nil)!
        for target in ["https://evil.example", "http://aether.cx", "https://user@aether.cx"] {
            guardDelegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: target)!)) { request in
                require(request == nil, "redirect delegate rejects before requesting " + target)
            }
        }
        let bounded = AetherRedirectGuard(hosts: ["aether.st", "aether.cx"])
        for attempt in 1...4 {
            bounded.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: "https://aether.cx/")!)) { request in
                require((request != nil) == (attempt <= 3), "trusted redirect chain bounded at attempt \(attempt)")
            }
        }
        let cancelled = Task { try await resolver.resolve(force: true) }; cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancellation must propagate") } catch is CancellationError {}
        require(true, "cancellation is not converted to a provider error")
        print("\(checks) Aether domain checks passed")
    }
}

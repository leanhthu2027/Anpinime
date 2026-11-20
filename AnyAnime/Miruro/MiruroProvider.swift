import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CoreFoundation)
import CoreFoundation
#endif
#if canImport(WebKit) && canImport(UIKit)
import WebKit
import UIKit
#endif

/// SvelteKit streams a reference table and separate deferred chunks as NDJSON.
struct MiruroPage {
    typealias Object = [String: Any]
    private let nodes: [[Any]]
    private let chunks: [Int: [Any]]

    init(_ data: Data) throws {
        guard data.count <= 8 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw AnimeServiceError.invalidResponse
        }
        var nodes: [[Any]] = []
        var chunks: [Int: [Any]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{") else { continue }
            let packet = try JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? Object
            if let entries = packet?["nodes"] as? [Any] {
                nodes += entries.compactMap { ($0 as? Object)?["data"] as? [Any] }
            } else if packet?["type"] as? String == "chunk", let id = Self.intIndex(packet?["id"]),
                      let table = packet?["data"] as? [Any] {
                chunks[id] = table
            }
        }
        guard !nodes.isEmpty else { throw AnimeServiceError.emptyData }
        self.nodes = nodes
        self.chunks = chunks
    }

    func field(_ key: String) -> Any? {
        for table in nodes.reversed() {
            if let root = table.first as? Object, let index = Self.intIndex(root[key]) {
                var budget = 100_000
                return decode(index, in: table, depth: 0, budget: &budget)
            }
        }
        return nil
    }

    func chunkMatching(_ predicate: (Object) -> Bool) -> Object? {
        for id in chunks.keys.sorted() {
            guard let table = chunks[id] else { continue }
            var budget = 100_000
            if let decoded = decode(0, in: table, depth: 0, budget: &budget) as? Object,
               predicate(decoded) {
                return decoded
            }
        }
        return nil
    }

    private static func intIndex(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if value is Bool { return nil }
        #if canImport(CoreFoundation)
        if CFGetTypeID(value as AnyObject) == CFBooleanGetTypeID() { return nil }
        #endif
        return value as? Int
    }

    private func decode(_ index: Int, in table: [Any], depth: Int, budget: inout Int) -> Any? {
        guard table.indices.contains(index), depth < 48, budget > 0 else { return nil }
        budget -= 1
        let value = table[index]
        if let object = value as? Object {
            var decoded: Object = [:]
            for (key, reference) in object {
                if let next = Self.intIndex(reference) {
                    decoded[key] = decode(next, in: table, depth: depth + 1, budget: &budget)
                }
            }
            return decoded
        }
        if let array = value as? [Any] {
            if array.first as? String == "Promise", array.count == 2,
               let rawRef = Self.intIndex(array[1]) {
                if table.indices.contains(rawRef),
                   let id = Self.intIndex(table[rawRef]),
                   let chunk = chunks[id] {
                    return decode(0, in: chunk, depth: depth + 1, budget: &budget)
                }
                if let chunk = chunks[rawRef] {
                    return decode(0, in: chunk, depth: depth + 1, budget: &budget)
                }
            }
            return array.compactMap { entry -> Any? in
                guard let next = Self.intIndex(entry) else { return nil }
                return decode(next, in: table, depth: depth + 1, budget: &budget)
            }
        }
        return value is NSNull ? nil : value
    }
}

#if canImport(WebKit) && canImport(UIKit)
@MainActor
private final class MiruroWebBridge: NSObject, WKNavigationDelegate {
    static let shared = MiruroWebBridge()
    static let mirrors: [URL] = [
        URL(string: "https://miruro.cx/")!,
        URL(string: "https://miruro.tv/")!,
        URL(string: "https://miruro.to/")!
    ]
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    private(set) var activeOrigin: URL = URL(string: "https://miruro.cx/")!
    private var webView: WKWebView?
    private var warmedAt: Date = .distantPast
    private var warmTask: Task<URL, Error>?
    private weak var presentedHost: UIViewController?
    private var navigationContinuation: CheckedContinuation<Void, Never>?
    private var navigationToken = UUID()

    private func ensureWebView() -> WKWebView {
        if let webView {
            attachHiddenIfNeeded(webView)
            return webView
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 720), configuration: config)
        view.customUserAgent = Self.userAgent
        view.navigationDelegate = self
        view.isOpaque = false
        view.backgroundColor = .clear
        self.webView = view
        attachHiddenIfNeeded(view)
        return view
    }

    private func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first
    }

    private func attachHiddenIfNeeded(_ webView: WKWebView) {
        guard presentedHost == nil else { return }
        guard let window = keyWindow() else { return }
        if webView.superview !== window {
            webView.removeFromSuperview()
            webView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            webView.alpha = 0.01
            webView.isUserInteractionEnabled = false
            window.addSubview(webView)
        }
    }

    private func presentInteractive(_ webView: WKWebView) {
        guard presentedHost == nil, let window = keyWindow() else { return }
        var top = window.rootViewController
        while let next = top?.presentedViewController { top = next }
        guard let presenter = top else { return }

        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        controller.title = "Xác minh Miruro"
        webView.removeFromSuperview()
        webView.alpha = 1
        webView.isUserInteractionEnabled = true
        webView.frame = controller.view.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(webView)

        let nav = UINavigationController(rootViewController: controller)
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Đóng",
            style: .done,
            target: self,
            action: #selector(dismissInteractive)
        )
        nav.modalPresentationStyle = .pageSheet
        presentedHost = nav
        presenter.present(nav, animated: true)
    }

    @objc private func dismissInteractive() {
        guard let host = presentedHost else { return }
        presentedHost = nil
        host.dismiss(animated: true) { [weak self] in
            Task { @MainActor in
                if let webView = self?.webView { self?.attachHiddenIfNeeded(webView) }
            }
        }
    }

    private func syncCookies() async {
        let cookies = await withCheckedContinuation { (continuation: CheckedContinuation<[HTTPCookie], Never>) in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    func invalidateWarmup() {
        warmedAt = .distantPast
    }

    func ensureWarm(force: Bool = false) async throws -> URL {
        if !force, Date().timeIntervalSince(warmedAt) < 1200, let webView,
           let host = webView.url?.host?.lowercased(),
           Self.mirrors.contains(where: { $0.host?.lowercased() == host }) {
            return activeOrigin
        }
        if let warmTask {
            return try await warmTask.value
        }
        let task = Task<URL, Error> { @MainActor [weak self] in
            guard let self else { throw AnimeServiceError.invalidResponse }
            defer { self.warmTask = nil }
            let webView = self.ensureWebView()
            let orderedMirrors = [self.activeOrigin] + Self.mirrors.filter { $0.host != self.activeOrigin.host }
            var lastError: Error = AnimeServiceError.http(403)
            for mirror in orderedMirrors {
                try Task.checkCancellation()
                let ok = await self.warmMirror(mirror, in: webView)
                if ok {
                    self.activeOrigin = mirror
                    self.warmedAt = Date()
                    await self.syncCookies()
                    self.dismissInteractive()
                    return mirror
                }
                lastError = AnimeServiceError.verificationRequired(mirror)
            }
            self.dismissInteractive()
            throw lastError
        }
        warmTask = task
        return try await task.value
    }

    private func warmMirror(_ origin: URL, in webView: WKWebView) async -> Bool {
        var req = URLRequest(url: origin, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        webView.load(req)
        await waitForNavigation(timeoutSeconds: 8)

        let inspectJS = """
        (() => {
          const title = (document.title || '').toLowerCase();
          const html = (document.documentElement && document.documentElement.innerHTML || '');
          const isCF = title.includes('just a moment') || title.includes('attention required')
            || html.includes('cf-browser-verification') || html.includes('challenge-platform')
            || html.includes('challenges.cloudflare.com');
          const hasInteractive = Boolean(document.querySelector('iframe[src*="challenges.cloudflare.com"],.cf-turnstile,#challenge-stage input[type="checkbox"]'));
          const ready = !isCF && document.body && (document.body.innerText || '').trim().length > 40;
          return { ready, isCF, hasInteractive };
        })()
        """

        let start = Date()
        var shownInteractive = false
        while Date().timeIntervalSince(start) < 28 {
            if Task.isCancelled { return false }
            if let result = try? await webView.evaluateJavaScript(inspectJS) as? [String: Any] {
                let ready = result["ready"] as? Bool ?? false
                let isCF = result["isCF"] as? Bool ?? false
                let hasInteractive = result["hasInteractive"] as? Bool ?? false
                if ready { return true }
                if isCF, hasInteractive, !shownInteractive, Date().timeIntervalSince(start) > 6 {
                    shownInteractive = true
                    presentInteractive(webView)
                }
            }
            if shownInteractive, presentedHost == nil {
                // User manually dismissed verification sheet
                return false
            }
            try? await Task.sleep(nanoseconds: 450_000_000)
        }
        return false
    }

    private func waitForNavigation(timeoutSeconds: Double) async {
        let token = UUID()
        navigationToken = token
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            navigationContinuation?.resume()
            navigationContinuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                guard let self, self.navigationToken == token else { return }
                self.navigationContinuation?.resume()
                self.navigationContinuation = nil
            }
        }
    }

    func fetchBatch(paths: [String]) async throws -> [String: (status: Int, body: String)] {
        guard !paths.isEmpty else { return [:] }
        _ = try await ensureWarm(force: false)
        let webView = ensureWebView()
        let firstTry = try await runBatchJS(paths: paths, in: webView)
        let blocked = firstTry.values.contains { $0.status == 403 || $0.status == 503 || Self.looksLikeCloudflare($0.body) }
        if blocked {
            invalidateWarmup()
            _ = try await ensureWarm(force: true)
            return try await runBatchJS(paths: paths, in: webView)
        }
        return firstTry
    }

    func fetch(path: String) async throws -> Data {
        let map = try await fetchBatch(paths: [path])
        guard let entry = map[path] else { throw AnimeServiceError.invalidResponse }
        guard (200..<300).contains(entry.status) else { throw AnimeServiceError.http(entry.status) }
        guard !Self.looksLikeCloudflare(entry.body) else { throw AnimeServiceError.http(403) }
        return Data(entry.body.utf8)
    }

    private func runBatchJS(paths: [String], in webView: WKWebView) async throws -> [String: (status: Int, body: String)] {
        let script = """
        const entries = await Promise.all(paths.map(async (p) => {
          try {
            const resp = await fetch(p, {
              method: 'GET',
              credentials: 'include',
              headers: { 'Accept': 'application/json,text/sveltekit-data,*/*' }
            });
            const text = await resp.text();
            return [p, { status: resp.status, body: text }];
          } catch (e) {
            return [p, { status: 0, body: String(e && e.message || e) }];
          }
        }));
        return Object.fromEntries(entries);
        """
        let raw = try await webView.callAsyncJavaScript(script, arguments: ["paths": paths], in: nil, contentWorld: .page)
        guard let dict = raw as? [String: Any] else { throw AnimeServiceError.invalidResponse }
        var out: [String: (status: Int, body: String)] = [:]
        for (path, val) in dict {
            guard let row = val as? [String: Any],
                  let status = row["status"] as? Int,
                  let body = row["body"] as? String else { continue }
            out[path] = (status, body)
        }
        return out
    }

    static func looksLikeCloudflare(_ text: String) -> Bool {
        let head = String(text.prefix(1024)).lowercased()
        return head.contains("just a moment") || head.contains("cf-browser-verification") || head.contains("challenges.cloudflare.com")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationContinuation?.resume()
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume()
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume()
        navigationContinuation = nil
    }
}
#endif

@MainActor
final class MiruroProvider: MovieSourceProviding {
    typealias Object = MiruroPage.Object

    private static let mirrorHosts: Set<String> = ["miruro.cx", "miruro.tv", "miruro.to"]
    private static let safariUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    private var activeBaseURL = URL(string: "https://miruro.cx/")!
    var baseURL: URL { activeBaseURL }

    let categories: [AnimeCategory] = [
        .init(title: "Thịnh hành", path: "sort=TRENDING_DESC"),
        .init(title: "Phổ biến", path: "sort=POPULARITY_DESC"),
        .init(title: "Điểm cao", path: "sort=SCORE_DESC"),
        .init(title: "Đang chiếu", path: "status=RELEASING"),
        .init(title: "Sắp chiếu", path: "status=NOT_YET_RELEASED"),
        .init(title: "Trọn bộ", path: "status=FINISHED"),
        .init(title: "Phim lẻ", path: "format=MOVIE"),
        .init(title: "Phim bộ", path: "format=TV"),
        .init(title: "OVA", path: "format=OVA")
    ] + ["Action", "Adventure", "Comedy", "Drama", "Fantasy", "Horror", "Mecha",
         "Mystery", "Psychological", "Romance", "Sci-Fi", "Slice of Life", "Sports",
         "Supernatural", "Thriller"].map { AnimeCategory(title: $0, path: "genre=" + $0) }
    let notice = ""

    private let session: URLSession
    private let usesExternalSession: Bool
    private var preferWebBridgeUntil: Date = .distantPast
    private var initialStreams: (url: URL, date: Date, streams: [NativeStream])?
    private var homeCache: (date: Date, sections: [AnimeSection])?
    private var detailCache: [String: (date: Date, detail: AnimeDetail)] = [:]
    private var sourcesCache: [String: (date: Date, streams: [NativeStream])] = [:]

    init(session suppliedSession: URLSession? = nil) {
        self.usesExternalSession = suppliedSession != nil
        if let suppliedSession {
            self.session = suppliedSession
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 25
            config.httpCookieStorage = .shared
            config.httpShouldSetCookies = true
            self.session = URLSession(configuration: config)
        }
    }

    func invalidate() {
        initialStreams = nil
        homeCache = nil
        detailCache.removeAll()
        sourcesCache.removeAll()
    }

    func home(onInitial: ([AnimeSection]) -> Void) async throws -> [AnimeSection] {
        if !usesExternalSession, let cached = homeCache, Date().timeIntervalSince(cached.date) < 180 {
            onInitial(cached.sections)
            return cached.sections
        }

        if usesExternalSession {
            let page = try MiruroPage(await request(activeBaseURL.appendingPathComponent("__data.json")))
            let sections = parseHomeSections(from: page)
            guard !sections.isEmpty else { throw AnimeServiceError.emptyData }
            onInitial(sections)
            return sections
        }

        let homePath = "/__data.json"
        let trendingPath = "/api/search/browse?sort=TRENDING_DESC&type=ANIME&limit=24&page=1&offset=0"
        let popularPath = "/api/search/browse?sort=POPULARITY_DESC&type=ANIME&limit=24&page=1&offset=0"
        let moviePath = "/api/search/browse?format=MOVIE&sort=POPULARITY_DESC&type=ANIME&limit=24&page=1&offset=0"

        let batch = try await requestBatch(paths: [homePath, trendingPath, popularPath, moviePath])

        var sections: [AnimeSection] = []
        if let homeData = batch[homePath], let page = try? MiruroPage(homeData) {
            sections = parseHomeSections(from: page)
        }

        func parseBrowse(_ data: Data?) -> [Anime] {
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? Object,
                  let rows = json["data"] as? [Object] else { return [] }
            return catalogItems(rows)
        }

        let trending = parseBrowse(batch[trendingPath])
        let popular = parseBrowse(batch[popularPath])
        let movies = parseBrowse(batch[moviePath])

        if !trending.isEmpty {
            sections.append(.init(title: "Thịnh hành", items: trending, categoryPath: "sort=TRENDING_DESC"))
        }
        if !popular.isEmpty {
            sections.append(.init(title: "Phổ biến nhất", items: popular, categoryPath: "sort=POPULARITY_DESC"))
        }
        if !movies.isEmpty {
            sections.append(.init(title: "Phim lẻ (Movie)", items: movies, categoryPath: "format=MOVIE"))
        }

        guard !sections.isEmpty else { throw AnimeServiceError.emptyData }
        homeCache = (Date(), sections)
        onInitial(sections)
        return sections
    }

    private func parseHomeSections(from page: MiruroPage) -> [AnimeSection] {
        let rails = (page.field("rails") as? Object) ?? page.chunkMatching { $0["raw"] != nil || $0["dub"] != nil }
        let side = (page.field("sideLists") as? Object) ?? page.chunkMatching { $0["airing"] != nil || $0["upcoming"] != nil }
        var sections: [AnimeSection] = []
        func append(_ title: String, _ rows: Any?, path: String? = nil) {
            let items = catalogItems(rows as? [Object] ?? [])
            if !items.isEmpty { sections.append(.init(title: title, items: items, categoryPath: path)) }
        }
        append("Nổi bật", page.field("hero") ?? page.field("spotlight"))
        append("Tập mới · Phụ đề", (rails?["raw"] as? Object)?["latest"])
        append("Tập mới · Lồng tiếng", (rails?["dub"] as? Object)?["latest"])
        append("Đang chiếu", side?["airing"], path: "status=RELEASING")
        append("Sắp chiếu", side?["upcoming"], path: "status=NOT_YET_RELEASED")
        return sections
    }

    func list(path: String, page: Int) async throws -> [Anime] {
        guard categories.contains(where: { $0.path == path }), page > 0,
              let separator = path.firstIndex(of: "=") else { return [] }
        let name = String(path[..<separator])
        var filters = [URLQueryItem(name: name, value: String(path[path.index(after: separator)...]))]
        if name != "sort" { filters.append(.init(name: "sort", value: "POPULARITY_DESC")) }
        return try await browse(filters, page: page)
    }

    func search(_ query: String) async throws -> [Anime] {
        try await browse([.init(name: "q", value: query)], page: 1)
    }

    private func browse(_ filters: [URLQueryItem], page: Int) async throws -> [Anime] {
        var route = URLComponents(url: activeBaseURL.appendingPathComponent("api/search/browse"), resolvingAgainstBaseURL: false)!
        route.queryItems = filters + [.init(name: "type", value: "ANIME"), .init(name: "limit", value: "24"),
                                      .init(name: "page", value: String(page)), .init(name: "offset", value: String((page - 1) * 24))]
        guard let url = route.url, let json = try JSONSerialization.jsonObject(with: await request(url)) as? Object,
              let items = json["data"] as? [Object] else { throw AnimeServiceError.invalidResponse }
        return catalogItems(items)
    }

    func detail(_ anime: Anime) async throws -> AnimeDetail {
        guard anime.source == .miruro, watchRoute(anime.url) else { throw AnimeServiceError.invalidURL }
        let mediaID = anime.url.pathComponents[2]
        if !usesExternalSession, let cached = detailCache[mediaID], Date().timeIntervalSince(cached.date) < 300 {
            return cached.detail
        }
        let rebasedURL = rebaseToActiveHost(anime.url)
        let page = try await watchPage(rebasedURL, number: "1")
        var detail = try detail(from: page, anime: anime)

        // Fallback to /api/episodes if watchPage chunk omitted episodes
        if !usesExternalSession, detail.episodes.isEmpty {
            var epRoute = URLComponents(url: activeBaseURL.appendingPathComponent("api/episodes"), resolvingAgainstBaseURL: false)!
            epRoute.queryItems = [.init(name: "id", value: mediaID)]
            if let epURL = epRoute.url,
               let epData = try? await request(epURL),
               let epJSON = try? JSONSerialization.jsonObject(with: epData) as? Object,
               let rows = epJSON["episodes"] as? [Object] ?? (epJSON["data"] as? [Object]) {
                let fallbackEpisodes = parseEpisodeRows(rows, baseWatchURL: anime.url)
                if !fallbackEpisodes.isEmpty {
                    detail = AnimeDetail(title: detail.title, posterURL: detail.posterURL, bannerURL: detail.bannerURL,
                                         summary: detail.summary, info: detail.info, episodes: fallbackEpisodes)
                }
            }
        }

        if let first = detail.episodes.first(where: { $0.number == 1 }) {
            let options = streams(from: page, episode: 1)
            initialStreams = options.isEmpty ? nil : (first.url, Date(), options)
            if !options.isEmpty {
                sourcesCache["\(mediaID):1"] = (Date(), options)
            }
        }
        if !usesExternalSession {
            if detailCache.count >= 40 { detailCache.removeAll() }
            detailCache[mediaID] = (Date(), detail)
        }
        return detail
    }

    func detail(from page: MiruroPage, anime: Anime) throws -> AnimeDetail {
        guard let media = page.field("media") as? Object else { throw AnimeServiceError.emptyData }
        let decoded = (page.field("episodesData") as? Object) ?? page.chunkMatching { $0["episodes"] is [Object] }
        let items = decoded?["episodes"] as? [Object] ?? []
        let episodes = parseEpisodeRows(items, baseWatchURL: anime.url)
        let cover = media["coverImage"] as? Object
        return AnimeDetail(title: title(media) ?? anime.title,
                           posterURL: Self.remoteURL(cover?["large"]) ?? anime.imageURL,
                           bannerURL: Self.remoteURL(media["bannerImage"]) ?? anime.bannerURL,
                           summary: (media["description"] as? String ?? anime.summary).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression),
                           info: [media["format"] as? String, (media["seasonYear"] as? Int).map(String.init)].compactMap { $0 }.joined(separator: " · "),
                           episodes: episodes)
    }

    private func parseEpisodeRows(_ items: [Object], baseWatchURL: URL) -> [Episode] {
        var seen = Set<Double>()
        return items.compactMap { row -> Episode? in
            guard let number = row["number"] as? NSNumber, number.doubleValue.isFinite,
                  number.doubleValue > 0, number.doubleValue < 100_000,
                  seen.insert(number.doubleValue).inserted,
                  var route = URLComponents(url: baseWatchURL, resolvingAgainstBaseURL: false) else { return nil }
            route.queryItems = [.init(name: "ep", value: number.stringValue)]
            guard let url = route.url else { return nil }
            let label = "Tập " + number.stringValue
            let name = row["title"] as? String
            return Episode(title: name.flatMap { $0.isEmpty ? nil : label + " · " + $0 } ?? label,
                           url: url, number: Int(exactly: number.doubleValue), season: "Miruro",
                           source: .miruro)
        }
    }

    func resolve(_ episode: Episode, refresh: Bool) async throws -> ResolvedPlayback {
        guard episode.source == .miruro, watchRoute(episode.url),
              let rawNumber = URLComponents(url: episode.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "ep" })?.value,
              let number = Double(rawNumber) else { throw AnimeServiceError.invalidURL }
        let mediaID = episode.url.pathComponents[2]
        let cacheKey = "\(mediaID):\(rawNumber)"
        var options: [NativeStream] = []

        if !refresh, let cached = initialStreams, cached.url == episode.url, Date().timeIntervalSince(cached.date) < 180 {
            options = cached.streams
        } else if !refresh, !usesExternalSession, let cached = sourcesCache[cacheKey], Date().timeIntervalSince(cached.date) < 1200 {
            options = cached.streams
        } else {
            var route = URLComponents(url: activeBaseURL.appendingPathComponent("api/sources"), resolvingAgainstBaseURL: false)!
            route.queryItems = [.init(name: "id", value: mediaID), .init(name: "n", value: rawNumber)]
            if let data = try? await request(route.url!),
               let json = try? JSONSerialization.jsonObject(with: data) as? Object {
                options = streams(from: json, episode: number)
            }
            if options.isEmpty, !usesExternalSession {
                if let page = try? await watchPage(rebaseToActiveHost(episode.url), number: rawNumber) {
                    options = streams(from: page, episode: number)
                }
            }
            if !options.isEmpty, !usesExternalSession {
                if sourcesCache.count >= 60 { sourcesCache.removeAll() }
                sourcesCache[cacheKey] = (Date(), options)
            }
        }

        if !usesExternalSession, options.count > 1 {
            options = await prioritizeHealthyStream(options)
        }

        guard let first = options.first else { throw AnimeServiceError.emptyData }
        return ResolvedPlayback(url: first.url, headers: first.headers, webURL: nil, isWeb: false,
                                nativeFallbacks: Array(options.dropFirst()), captions: first.captions, label: first.label)
    }

    func streams(from page: MiruroPage, episode: Double) -> [NativeStream] {
        let data = (page.field("sourcesData") as? Object) ?? page.chunkMatching { $0["tracks"] is [Object] }
        return streams(from: data, episode: episode)
    }

    private func streams(from data: Object?, episode: Double) -> [NativeStream] {
        guard let data else { return [] }
        if let epNum = data["episodeNumber"] as? NSNumber, epNum.doubleValue != episode { return [] }
        guard let tracks = data["tracks"] as? [Object] else { return [] }
        let order = data["providerOrder"] as? [String] ?? []
        let config = data["config"] as? [String: Object] ?? [:]

        // First pass: gather all subtitles across sibling providers so providers without
        // own subtitles (e.g. `bee`) inherit Vietnamese/English softsubs from `sun`/`hop`.
        var sharedCaptions: [RemoteCaption] = []
        var sharedCaptionURLs = Set<URL>()
        for row in tracks {
            for provider in row["providers"] as? [Object] ?? [] {
                let providerHeaders = Self.extractSafeHeaders(
                    (provider["servers"] as? [Object])?.first?["headers"] as? [String: String] ?? [:]
                )
                for subtitle in provider["subtitles"] as? [Object] ?? [] {
                    guard let url = Self.remoteURL(subtitle["file"]),
                          let label = subtitle["label"] as? String,
                          sharedCaptionURLs.insert(url).inserted else { continue }
                    let lang = subtitle["language"] as? String ?? ""
                    let captionHeaders = Self.cdnHeaders(for: url, existing: providerHeaders)
                    sharedCaptions.append(RemoteCaption(title: label, language: lang, url: url, headers: captionHeaders))
                }
            }
        }
        sharedCaptions = Self.sortCaptionsVietnameseFirst(sharedCaptions)

        var seen = Set<URL>()
        var options: [NativeStream] = []
        // Soft subs first, then subtitled video and dubbed audio.
        for track in ["ssub", "sub", "dub", "raw"] {
            for row in tracks where row["track"] as? String == track {
                let providers = row["providers"] as? [Object] ?? []
                func priority(_ provider: Object) -> Int {
                    order.firstIndex(of: provider["provider"] as? String ?? "") ?? order.count
                }
                for provider in providers.sorted(by: { priority($0) < priority($1) }) {
                    let providerName = provider["provider"] as? String ?? ""
                    if !providerName.isEmpty, config[providerName]?["visible"] as? Bool == false { continue }
                    for (serverIdx, server) in (provider["servers"] as? [Object] ?? []).enumerated() {
                        let baseHeaders = Self.extractSafeHeaders(server["headers"] as? [String: String] ?? [:])
                        var ownCaptions = (provider["subtitles"] as? [Object] ?? []).compactMap { subtitle -> RemoteCaption? in
                            guard let url = Self.remoteURL(subtitle["file"]), let label = subtitle["label"] as? String else { return nil }
                            return RemoteCaption(title: label, language: subtitle["language"] as? String ?? "",
                                                 url: url, headers: Self.cdnHeaders(for: url, existing: baseHeaders))
                        }
                        if ownCaptions.isEmpty {
                            ownCaptions = sharedCaptions
                        } else if !sharedCaptions.isEmpty {
                            var ownURLs = Set(ownCaptions.map(\.url))
                            let extra = sharedCaptions.filter { ownURLs.insert($0.url).inserted }
                            ownCaptions = Self.sortCaptionsVietnameseFirst(ownCaptions + extra)
                        }
                        let serverTitle = (server["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let trackBadge: String = {
                            switch track {
                            case "ssub": return "SoftSub"
                            case "sub": return "Sub"
                            case "dub": return "Dub"
                            default: return "Raw"
                            }
                        }()
                        let displayProvider = providerName.isEmpty ? "Server \(serverIdx + 1)" : providerName.capitalized
                        let label = serverTitle.isEmpty ? "\(displayProvider) · \(trackBadge)" : "\(displayProvider) (\(serverTitle)) · \(trackBadge)"
                        for stream in server["streams"] as? [Object] ?? [] {
                            guard ["hls", "mp4"].contains(stream["format"] as? String ?? ""),
                                  let url = Self.remoteURL(stream["url"]), seen.insert(url).inserted else { continue }
                            let finalHeaders = Self.cdnHeaders(for: url, existing: baseHeaders)
                            options.append(NativeStream(url: url, headers: finalHeaders, captions: ownCaptions, label: label))
                        }
                    }
                }
            }
        }
        return Array(options.prefix(12))
    }

    private static func extractSafeHeaders(_ raw: [String: String]) -> [String: String] {
        raw.filter { name, value in
            ["origin", "referer", "user-agent"].contains(name.lowercased())
                && !value.contains("\r") && !value.contains("\n")
        }
    }

    /// Supply known Miruro CDN Origin/Referer defaults ONLY when the host matches a real CDN
    /// and the server response omitted them. Never mutates unknown/fixture hosts.
    private static func cdnHeaders(for url: URL, existing: [String: String]) -> [String: String] {
        guard let host = url.host?.lowercased() else { return existing }
        let hasOrigin = existing.keys.contains { $0.lowercased() == "origin" }
        let hasReferer = existing.keys.contains { $0.lowercased() == "referer" }
        var out = existing
        if host.contains("pearlwinter.top") || host.contains("sunwaveclear.top") || host.contains("keeply.top") {
            if !hasOrigin { out["Origin"] = "https://strm.cx" }
            if !hasReferer { out["Referer"] = "https://strm.cx/" }
        } else if host.contains("krussdomi.com") || host.contains("advancedairesearchlab.xyz") {
            if !hasOrigin { out["Origin"] = "https://krussdomi.com" }
            if !hasReferer { out["Referer"] = "https://krussdomi.com/" }
        } else if host.contains("megaplay.buzz") || host.contains("nexabloom.top") || host.contains("shiora.top")
                    || host.contains("akirax.buzz") || host.contains("laggedduringcutscene.site") || host.contains("imgnex.top") {
            if !hasReferer { out["Referer"] = "https://megaplay.buzz/" }
        }
        return out
    }

    private static func sortCaptionsVietnameseFirst(_ captions: [RemoteCaption]) -> [RemoteCaption] {
        func rank(_ caption: RemoteCaption) -> Int {
            let lang = caption.language.lowercased()
            let title = caption.title.lowercased()
            if lang.hasPrefix("vi") || title.contains("viet") || title.contains("tiếng việt") { return 0 }
            if lang.hasPrefix("en") || title.contains("english") { return 1 }
            return 2
        }
        return captions.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    private func prioritizeHealthyStream(_ streams: [NativeStream]) async -> [NativeStream] {
        let probeCount = min(3, streams.count)
        let candidates = Array(streams.prefix(probeCount))
        let probeSession: URLSession = {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 3.5
            cfg.timeoutIntervalForResource = 4.0
            return URLSession(configuration: cfg)
        }()
        defer { probeSession.invalidateAndCancel() }

        let winnerIndex: Int? = await withTaskGroup(of: (Int, Bool).self) { group in
            for (idx, stream) in candidates.enumerated() {
                group.addTask {
                    var req = URLRequest(url: stream.url)
                    req.setValue(Self.safariUserAgent, forHTTPHeaderField: "User-Agent")
                    for (k, v) in stream.headers { req.setValue(v, forHTTPHeaderField: k) }
                    guard let (data, resp) = try? await probeSession.data(for: req),
                          let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          !data.isEmpty else {
                        return (idx, false)
                    }
                    let head = String(data: data.prefix(256), encoding: .utf8) ?? ""
                    let ok = head.contains("#EXTM3U") || stream.url.pathExtension.lowercased() == "mp4" || data.count > 128
                    return (idx, ok)
                }
            }
            var firstHealthy: Int?
            for await (idx, ok) in group {
                if ok {
                    firstHealthy = idx
                    group.cancelAll()
                    break
                }
            }
            return firstHealthy
        }

        guard let winnerIndex, winnerIndex > 0, winnerIndex < streams.count else { return streams }
        var reordered = streams
        let chosen = reordered.remove(at: winnerIndex)
        reordered.insert(chosen, at: 0)
        return reordered
    }

    func catalogItems(_ rows: [Object]) -> [Anime] {
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let id = row["animeId"] as? String ?? row["id"] as? String,
                  id.range(of: #"^[A-Za-z0-9_-]{1,100}$"#, options: .regularExpression) != nil,
                  let title = title(row), seen.insert(id).inserted else { return nil }
            let names = row["title"] as? Object
            // Miruro displays the selected language but canonicalizes watch URLs
            // using the shorter English/Romaji title, with English winning ties.
            let candidates = [names?["english"], names?["romaji"]].compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let routeTitle = candidates.min { $0.utf16.count < $1.utf16.count } ?? title
            let slug = routeTitle.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
                .lowercased().replacingOccurrences(of: #"[^a-z0-9\s-]"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"[\s-]+"#, with: "-", options: .regularExpression)
            var url = activeBaseURL.appendingPathComponent("watch").appendingPathComponent(id)
            if !slug.isEmpty && slug != id { url.appendPathComponent(slug) }
            let count = (row["episode"] ?? row["episodeCount"] ?? row["episode_count"]) as? NSNumber
            return Anime(title: title, url: url, imageURL: Self.remoteURL(row["coverUrl"] ?? row["cover_url"]),
                         bannerURL: Self.remoteURL(row["backdropUrl"] ?? row["backgroundUrl"] ?? row["banner_url"] ?? row["background_url"]),
                         episodeText: count.map { "Tập " + $0.stringValue } ?? "", quality: row["format"] as? String ?? "",
                         score: ((row["averageScore"] ?? row["average_score"]) as? NSNumber).map { String(format: "%.1f", $0.doubleValue / 10) } ?? "",
                         summary: (row["description"] as? String ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression),
                         source: .miruro)
        }
    }

    private func title(_ row: Object) -> String? {
        let names = row["title"] as? Object
        return [names?["english"], names?["romaji"], names?["native"]].compactMap { $0 as? String }.first { !$0.isEmpty }
    }

    private func watchRoute(_ url: URL) -> Bool {
        guard url.scheme == "https",
              let host = url.host?.lowercased(),
              Self.mirrorHosts.contains(host),
              url.user == nil, url.password == nil, url.port == nil,
              (3...4).contains(url.pathComponents.count),
              url.pathComponents[1] == "watch" else { return false }
        return true
    }

    private func rebaseToActiveHost(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.host = activeBaseURL.host
        return comps.url ?? url
    }

    private func watchPage(_ url: URL, number: String) async throws -> MiruroPage {
        var pageURL = url
        // Older saved cards may carry a noncanonical slug. SvelteKit can
        // return a JSON redirect instead of following it as an HTTP redirect.
        for _ in 0..<3 {
            var route = URLComponents(url: pageURL.appendingPathComponent("__data.json"), resolvingAgainstBaseURL: false)!
            route.queryItems = [.init(name: "ep", value: number), .init(name: "x-sveltekit-invalidated", value: "01")]
            let data = try await request(route.url!)
            if let packet = try? JSONSerialization.jsonObject(with: data) as? Object,
               packet["type"] as? String == "redirect" {
                guard let location = packet["location"] as? String,
                      let next = URL(string: location, relativeTo: pageURL)?.absoluteURL,
                      watchRoute(next), next.pathComponents[2] == url.pathComponents[2],
                      next.path != pageURL.path else { throw AnimeServiceError.invalidResponse }
                pageURL = next
                continue
            }
            return try MiruroPage(data)
        }
        throw AnimeServiceError.invalidResponse
    }

    private func relativePath(for url: URL) -> String {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.path }
        let path = comps.percentEncodedPath.isEmpty ? "/" : comps.percentEncodedPath
        if let query = comps.percentEncodedQuery, !query.isEmpty {
            return "\(path)?\(query)"
        }
        return path
    }

    private func requestBatch(paths: [String]) async throws -> [String: Data] {
        #if canImport(WebKit) && canImport(UIKit)
        if !usesExternalSession, Date() < preferWebBridgeUntil {
            let map = try await MiruroWebBridge.shared.fetchBatch(paths: paths)
            activeBaseURL = MiruroWebBridge.shared.activeOrigin
            var results: [String: Data] = [:]
            for (path, entry) in map where (200..<300).contains(entry.status) && !MiruroWebBridge.looksLikeCloudflare(entry.body) {
                results[path] = Data(entry.body.utf8)
            }
            if !results.isEmpty { return results }
        }
        #endif

        var results: [String: Data] = [:]
        var hitCloudflare = false
        await withTaskGroup(of: (String, Data?, Bool).self) { group in
            for path in paths {
                guard let url = URL(string: path, relativeTo: activeBaseURL)?.absoluteURL else { continue }
                group.addTask { [weak self] in
                    guard let self else { return (path, nil, false) }
                    do {
                        let data = try await self.directSessionRequest(url)
                        return (path, data, false)
                    } catch AnimeServiceError.http(let status) where status == 403 || status == 503 || status == 429 {
                        return (path, nil, true)
                    } catch {
                        return (path, nil, false)
                    }
                }
            }
            for await (path, data, blocked) in group {
                if let data { results[path] = data }
                if blocked { hitCloudflare = true }
            }
        }

        if !results.isEmpty && !hitCloudflare { return results }

        #if canImport(WebKit) && canImport(UIKit)
        if !usesExternalSession {
            preferWebBridgeUntil = Date().addingTimeInterval(300)
            let map = try await MiruroWebBridge.shared.fetchBatch(paths: paths)
            activeBaseURL = MiruroWebBridge.shared.activeOrigin
            for (path, entry) in map where (200..<300).contains(entry.status) && !MiruroWebBridge.looksLikeCloudflare(entry.body) {
                results[path] = Data(entry.body.utf8)
            }
            return results
        }
        #endif
        return results
    }

    private func directSessionRequest(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("application/json,text/sveltekit-data", forHTTPHeaderField: "Accept")
        req.setValue(activeBaseURL.absoluteString, forHTTPHeaderField: "Referer")
        if !usesExternalSession {
            req.setValue(Self.safariUserAgent, forHTTPHeaderField: "User-Agent")
        }
        let (data, response) = try await session.data(for: req)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw AnimeServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AnimeServiceError.http(http.statusCode) }
        guard let finalHost = http.url?.host?.lowercased(),
              Self.mirrorHosts.contains(finalHost),
              data.count <= 8 * 1024 * 1024 else { throw AnimeServiceError.invalidResponse }
        if !usesExternalSession,
           let head = String(data: data.prefix(512), encoding: .utf8)?.lowercased(),
           head.contains("just a moment") || head.contains("cf-browser-verification") {
            throw AnimeServiceError.http(403)
        }
        return data
    }

    private func request(_ url: URL) async throws -> Data {
        #if canImport(WebKit) && canImport(UIKit)
        if !usesExternalSession, Date() < preferWebBridgeUntil {
            let data = try await MiruroWebBridge.shared.fetch(path: relativePath(for: url))
            activeBaseURL = MiruroWebBridge.shared.activeOrigin
            return data
        }
        #endif

        do {
            return try await directSessionRequest(url)
        } catch let error {
            #if canImport(WebKit) && canImport(UIKit)
            if !usesExternalSession {
                let shouldBridge: Bool
                switch error {
                case AnimeServiceError.http(let status):
                    shouldBridge = (status == 403 || status == 503 || status == 429)
                case AnimeServiceError.invalidResponse:
                    shouldBridge = true
                default:
                    shouldBridge = false
                }
                if shouldBridge {
                    preferWebBridgeUntil = Date().addingTimeInterval(300)
                    let data = try await MiruroWebBridge.shared.fetch(path: relativePath(for: url))
                    activeBaseURL = MiruroWebBridge.shared.activeOrigin
                    return data
                }
            }
            #endif
            throw error
        }
    }

    private static func remoteURL(_ value: Any?) -> URL? {
        guard let string = value as? String, let url = URL(string: string), url.scheme == "https",
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

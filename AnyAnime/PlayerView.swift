import SwiftUI
import WebKit
import AVKit

struct PlayerControllerView: UIViewControllerRepresentable {
    let episode: Episode
    let service: AnimeService
    let playback: PlaybackState

    func makeUIViewController(context: Context) -> UIViewController {
        // A PiP host may outlive its dismissed SwiftUI presentation. End that
        // decoder explicitly before a different player acquires playback.
        NotificationCenter.default.post(name: Notification.Name("AnPinime.playerWillStart"), object: nil)
        if episode.source == .aether { return AetherPlayerViewController(episode: episode, service: service, playback: playback) }
        return AnimePlayerViewController(episode: episode, service: service, playback: playback)
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) { }
    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: ()) {
        (uiViewController as? AetherPlayerViewController)?.shutdown()
        (uiViewController as? AnimePlayerViewController)?.shutdown()
    }
}

private final class AnimeManifestRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var request = request
        if response.url?.host?.lowercased() != request.url?.host?.lowercased() {
            for name in ["Cookie", "Authorization", "Referer", "Origin"] { request.setValue(nil, forHTTPHeaderField: name) }
        }
        completionHandler(request)
    }
}

@MainActor
final class AnimePlayerViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, AVPlayerViewControllerDelegate {
    private static let animeManifestSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = .shared
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config, delegate: AnimeManifestRedirectPolicy(), delegateQueue: nil)
    }()
    private static let episodeSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()

    private let episodeURL: URL
    private let baseURL: URL
    private let episode: Episode
    private let service: AnimeService
    private let playback: PlaybackState
    private var active = true
    private var shutdownRequested = false
    private var retainedForPiP: AnimePlayerViewController?
    private let piPDiagnosticSessionID = UUID().uuidString
    private var avRestoreHandshake = NativePiPRestoreHandshake()
    private var avRestoreCompletion: ((Bool) -> Void)?
    private var avRestoreTimeout: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var nativeTimer: Timer?
    private var endedObserver: NSObjectProtocol?
    private var webEnded = false
    private var verificationTimer: Timer?
    private var nativeSource: URL?
    private var failedNativeSources = Set<URL>()
    private var nativeStartedAt = Date()
    private var preparingNative = false
    private var nativePrepareTask: Task<Void, Never>?
    private var webHandoffPending = false
    private var handoffFrame: WKFrameInfo?
    private var animeWebCaptions: [AetherSubtitle] = []
    private var animeWebCaptionTask: Task<Void, Never>?
    private var deferredDirectSource: (url: URL, referer: URL)?
    private var nativeFallbackPosition = 0.0
    private var websiteOwnsPlayback = false
    private var webPiPConfigured = false
    private var webPiPFrame: WKFrameInfo?
    private var webPiPSessionID: String?
    private var webHomeRequestID: String?
    private var webPiPRequestID: String?
    private var webPiPTimeout: Timer?
    private var directWebView: WKWebView?
    private var fallbackWebView: WKWebView?
    private var playerController: AVPlayerViewController?
    private var mpvController: MPVPlaybackController?
    private var fallbackTimer: Timer?
    private var revealTimer: Timer?
    private var fallbackLoadedURL: URL?
    private let loadingLabel = UILabel()
    private var providerHeaders: [String: String] = [:]
    private var providerIsWeb = false
    private var providerWebURL: URL?
    private var providerRefreshAttempted = false
    private var resumeAfterRefresh = 0.0
    private var mediaTracksLoaded = false
    private var filmRelay: FilmMediaRelay?
    private var trackTask: Task<Void, Never>?
    private var miruroAllStreams: [NativeStream] = []
    private var miruroStreamIndex = 0
    private var miruroCaptions: [AetherSubtitle] = []
    private var miruroLocalCaptions: [String: URL] = [:]
    private var miruroSelectedCaption: AetherSubtitle?
    private var miruroSelectedFile: URL?
    private var miruroCaptionTask: Task<Void, Never>?
    private var miruroRelayTask: Task<Void, Never>?
    private var miruroResumePosition = 0.0
    private let captionClient = AetherSubtitleClient()

    private var audioOptions: [String: AVMediaSelectionOption] = [:]
    private var subtitleOptions: [String: AVMediaSelectionOption] = [:]

    init(episode: Episode, service: AnimeService, playback: PlaybackState) {
        self.episode = episode
        self.service = service
        self.episodeURL = episode.source == .anime ? HTMLParser.rebasedAnimeURL(episode.url, baseURL: service.baseURL) : episode.url
        self.baseURL = service.baseURL
        self.playback = playback
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        loadingLabel.text = "Đang tải thông tin video…"
        loadingLabel.textColor = .white
        loadingLabel.textAlignment = .center
        loadingLabel.isHidden = true
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loadingLabel)
        NSLayoutConstraint.activate([
            loadingLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        playback.command = { [weak self] name, value in self?.perform(name, value: value) }
        playback.chooseOption = { [weak self] kind, id in self?.chooseOption(kind, id: id) }
        playback.importSubtitle = { [weak self] url, slot in self?.mpvController?.addSubtitle(url, slot: slot) }
        playback.translateSubtitle = { [weak self] in self?.translateMiruroCaption() }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-preview") {
            Task { @MainActor in
                if InterfacePreview.mode != "loading" {
                    self.playback.loading = false
                    self.playback.duration = 1440
                    self.playback.currentTime = 325
                    self.playback.playing = true
                    self.playback.audioTracks = [.init(id: "vi", title: "Tiếng Việt"), .init(id: "en", title: "English · Stereo")]
                    self.playback.audioTrack = "vi"
                    self.playback.subtitleTracks = [.init(id: "off", title: "Tắt phụ đề")] + (1...35).map { .init(id: "subtitle-\($0)", title: "Phụ đề ngôn ngữ \($0)") }
                    self.playback.subtitleTrack = "subtitle-12"
                    self.playback.qualities = [.automatic, .init(id: "1080", title: "1080p", bandwidth: 4000000, width: 1920, height: 1080)]
                }
            }
            return
        }
        #endif
        NotificationCenter.default.addObserver(self, selector: #selector(startWebPictureInPictureInBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(restoreWebForeground), name: UIApplication.didBecomeActiveNotification, object: nil)
        for name in ["AnPinime.sourceWillChange", "AnPinime.libraryWillChange", "AnPinime.playerWillStart"] {
            NotificationCenter.default.addObserver(self, selector: #selector(endForReplacement), name: Notification.Name(name), object: nil)
        }
        if episode.source != .anime { attemptProviderPlayer() }
        else { attemptDirectPlayer() }
    }

    @objc private func endForReplacement() { shutdown(force: true) }

    func shutdown(force: Bool = false) {
        guard active else { return }
        if NativePiPPolicy.shouldDeferTeardown(active: playback.pictureInPictureActive, pending: playback.pictureInPicturePending, explicitEnd: force) {
            // A representable can disappear during system presentation. Its
            // decoder, WKWebView and delegates must live until that owner stops.
            shutdownRequested = true; retainedForPiP = self
            tracePiP("teardownDeferred")
            return
        }
        active = false
        retainedForPiP = nil
        if let requestID = avRestoreHandshake.pendingID { completeAVRestore(requestID, success: false) }
        // SwiftUI can call shutdown from dismantleUIViewController while its
        // graph is being destroyed. Release bridge state without publishing to it.
        resetWebPictureInPicture(publishState: false)
        miruroCaptionTask?.cancel()
        miruroRelayTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        mpvController?.shutdown(); mpvController = nil
        requestTask?.cancel()
        nativePrepareTask?.cancel()
        animeWebCaptionTask?.cancel()
        filmRelay?.stop(); filmRelay = nil
        trackTask?.cancel()
        fallbackTimer?.invalidate()
        revealTimer?.invalidate()
        nativeTimer?.invalidate()
        verificationTimer?.invalidate()
        if let endedObserver { NotificationCenter.default.removeObserver(endedObserver) }
        playerController?.player?.pause()
        playerController?.delegate = nil
        playerController?.player?.replaceCurrentItem(with: nil)
        for webView in [directWebView, fallbackWebView] {
            webView?.evaluateJavaScript("window.postMessage({type:'AnPinimeCommand',name:'pipStop'},'*');document.querySelectorAll('video').forEach(v=>v.pause())")
            webView?.pauseAllMediaPlayback(completionHandler: nil)
            webView?.stopLoading()
            webView?.navigationDelegate = nil
            webView?.uiDelegate = nil
            ["videoFound", "playlistFound", "iframeFound", "playerReady", "playerError", "mediaState", "pipState"].forEach {
                webView?.configuration.userContentController.removeScriptMessageHandler(forName: $0)
            }
            webView?.loadHTMLString("", baseURL: nil)
        }
    }

    private func finishDeferredShutdown() {
        guard shutdownRequested, !playback.pictureInPicturePending, !playback.pictureInPictureActive else { return }
        shutdown()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); acknowledgeAVRestoreIfReady()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews(); acknowledgeAVRestoreIfReady()
    }

    private func configureWebPictureInPicture() {
        guard active, mpvController == nil, playerController == nil else { return }
        webPiPConfigured = true
        let automatic = UserDefaults.standard.object(forKey: "AnPinime.automaticPiP") as? Bool ?? true
        perform("automaticPiP", value: automatic ? 1 : 0)
    }

    private func resetWebPictureInPicture(publishState: Bool = true) {
        webPiPTimeout?.invalidate(); webPiPTimeout = nil
        if let frame = webPiPFrame, let sessionID = webPiPSessionID {
            fallbackWebView?.callAsyncJavaScript("window.__anpinimeArmHomePiP?.(sessionID, null, false)",
                arguments: ["sessionID": sessionID], in: frame, in: .page, completionHandler: nil)
        }
        webPiPSessionID = nil; webHomeRequestID = nil; webPiPRequestID = nil; webPiPFrame = nil
        guard publishState else { return }
        playback.pictureInPicturePending = false
        playback.pictureInPictureActive = false
        playback.pictureInPictureSupported = false
        playback.pictureInPictureError = nil
    }

    private func finishWebPictureInPictureRequest(_ requestID: String, sessionID: String,
                                                 error: String? = nil, stopped: Bool = false) {
        guard active, mpvController == nil, playerController == nil,
              webPiPRequestID == requestID, webPiPSessionID == sessionID,
              stopped || playback.pictureInPicturePending && !playback.pictureInPictureActive else { return }
        webPiPTimeout?.invalidate(); webPiPTimeout = nil
        playback.pictureInPicturePending = false
        if stopped { playback.pictureInPictureActive = false }
        playback.pictureInPictureError = error
        tracePiP(stopped ? "didStop" : "requestFinished")
        finishDeferredShutdown()
    }

    private func webPictureInPictureError(_ reason: String) -> String? {
        switch reason {
        case "": return nil
        case "paused", "automatic-disabled", "stopped": return nil
        case "unsupported": return "Video trên website này chưa hỗ trợ Hình trong hình."
        default: return "Chưa thể mở Hình trong hình từ website. Bạn có thể thử lại khi video đang phát."
        }
    }

    private func requestWebPictureInPicture(automatically: Bool) {
        guard let webView = fallbackWebView, let sessionID = webPiPSessionID,
              playback.playing, !playback.userPaused, playback.pictureInPictureSupported,
              !playback.pictureInPictureActive, !playback.pictureInPicturePending else { return }
        if automatically, !(UserDefaults.standard.object(forKey: "AnPinime.automaticPiP") as? Bool ?? true) { return }
        let requestID = (automatically ? webHomeRequestID : nil) ?? UUID().uuidString
        let payload: [String: Any] = ["type": "AnPinimeCommand", "name": automatically ? "pipAutomatically" : "pip",
                                      "requestID": requestID, "sessionID": sessionID]
        beginWebPiPRequest(requestID, sessionID: sessionID)
        webView.callAsyncJavaScript("window.__anpinimeRequestPiP && window.__anpinimeRequestPiP(command)",
                                    arguments: ["command": payload], in: webPiPFrame, in: .page) { [weak self] result in
            if case .failure = result, let self {
                self.finishWebPictureInPictureRequest(requestID, sessionID: sessionID,
                    error: self.webPictureInPictureError("evaluation"))
            }
        }
    }

    private func beginWebPiPRequest(_ requestID: String, sessionID: String) {
        webPiPRequestID = requestID
        // Publish ownership before WebKit evaluates anything. A queued inline
        // state or a temporary disappearance must not pause a starting request.
        playback.pictureInPicturePending = true
        playback.pictureInPictureError = nil
        tracePiP("startRequested")
        webPiPTimeout?.invalidate()
        webPiPTimeout = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.finishWebPictureInPictureRequest(requestID, sessionID: sessionID,
                    error: self.webPictureInPictureError("timeout"))
            }
        }
    }

    private func armWebHomeRequest(sessionID: String, frame: WKFrameInfo) {
        let id = UUID().uuidString
        webHomeRequestID = id
        let enabled = UserDefaults.standard.object(forKey: "AnPinime.automaticPiP") as? Bool ?? true
        fallbackWebView?.callAsyncJavaScript("return window.__anpinimeArmHomePiP(sessionID, requestID, enabled)",
            arguments: ["sessionID": sessionID, "requestID": id, "enabled": enabled], in: frame, in: .page) { [weak self] result in
            guard let self, self.webHomeRequestID == id else { return }
            if case .success(let armed) = result, armed as? Bool == true { return }
            self.webHomeRequestID = nil
        }
    }

    private func updateWebPictureInPicture(_ state: [String: Any], frame: WKFrameInfo) {
        guard let sessionID = state["pipSessionID"] as? String, !sessionID.isEmpty else { return }
        let requestID = state["pipRequestID"] as? String ?? ""
        if playback.pictureInPicturePending || playback.pictureInPictureActive {
            guard sessionID == webPiPSessionID, requestID == webPiPRequestID else { return }
        } else if sessionID != webPiPSessionID {
            webPiPSessionID = sessionID; webPiPRequestID = nil; webHomeRequestID = nil
        }
        webPiPFrame = frame
        if webHomeRequestID == nil, (state["pipSupported"] as? Bool) == true, UIApplication.shared.applicationState == .active {
            armWebHomeRequest(sessionID: sessionID, frame: frame)
        }
        playback.pictureInPictureSupported = (state["pipSupported"] as? Bool) == true
        if (state["pipActive"] as? Bool) == true {
            // WebKit can enter PiP through its own controls/system transition.
            // Adopt its identity, including an empty request ID, so the matching
            // stopped event can release this session later.
            webPiPRequestID = requestID
            playback.pictureInPictureActive = true
            webPiPTimeout?.invalidate(); webPiPTimeout = nil
            playback.pictureInPicturePending = false
            playback.pictureInPictureError = nil
            tracePiP("didStart")
        } else if !playback.pictureInPictureActive,
                  (state["pipPending"] as? Bool) != true, requestID == webPiPRequestID {
            finishWebPictureInPictureRequest(requestID, sessionID: sessionID,
                error: webPictureInPictureError(state["pipError"] as? String ?? ""))
        }
    }

    @objc private func startWebPictureInPictureInBackground() {
        guard UIApplication.shared.applicationState == .background,
              active, mpvController == nil, playerController == nil else { return }
        configureWebPictureInPicture()
        guard playback.playing, !playback.userPaused, !playback.pictureInPictureActive,
              !playback.pictureInPicturePending,
              UserDefaults.standard.object(forKey: "AnPinime.automaticPiP") as? Bool ?? true else { return }
        // Public WKWebView API has no AVKit-style automatic-inline PiP flag.
        // This is a best-effort request on actual background, separate from the
        // manual command; it must never run merely because the app is inactive.
        perform("pipAutomatically", value: 1)
    }

    @objc private func restoreWebForeground() {
        guard active else { return }
        if let controller = playerController {
            controller.canStartPictureInPictureAutomaticallyFromInline = UserDefaults.standard.object(forKey: "AnPinime.automaticPiP") as? Bool ?? true
            updateNativeState()
            acknowledgeAVRestoreIfReady()
            return
        }
        guard active, mpvController == nil, playerController == nil else { return }
        if let source = deferredDirectSource, directWebView != nil {
            deferredDirectSource = nil
            showNativePlayer(url: source.url, referer: source.referer)
        } else {
            webHomeRequestID = nil
            configureWebPictureInPicture()
        }
    }

    private func perform(_ name: String, value: Double) {
        guard active else { return }
        if let mpvController {
            if webHandoffPending, ["play", "pause", "seek", "rate", "volume"].contains(name),
               let webView = fallbackWebView, let frame = handoffFrame {
                webView.callAsyncJavaScript("window.__anpinimeHandoffCommand && window.__anpinimeHandoffCommand(name, value)",
                    arguments: ["name": name, "value": value], in: frame, in: .page, completionHandler: nil)
            }
            if webHandoffPending, name == "volume" { return }
            mpvController.perform(name, value: value)
            return
        }
        if let player = playerController?.player {
            switch name {
            case "play": player.playImmediately(atRate: Float(playback.rate))
            case "pause": player.pause()
            case "seek":
                let target = min(max(0, value), max(0, playback.duration))
                player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
            case "rate": if player.rate != 0 { player.rate = Float(value) }
            case "volume": player.volume = Float(value)
            case "fit": playerController?.videoGravity = value == 1 ? .resizeAspectFill : .resizeAspect
            case "subtitleSize", "subtitleBackground": applySubtitleStyle()
            default: break
            }
        } else {
            if name == "pip" || name == "pipAutomatically" {
                requestWebPictureInPicture(automatically: name == "pipAutomatically")
                return
            }
            if name == "pipStop", let requestID = webPiPRequestID, let sessionID = webPiPSessionID {
                finishWebPictureInPictureRequest(requestID, sessionID: sessionID, stopped: true)
            }
            var payload: [String: Any] = ["type": "AnPinimeCommand", "name": name, "value": value]
            if name == "subtitleStyle", let data = try? JSONEncoder().encode(playback.subtitleStyle),
               let style = try? JSONSerialization.jsonObject(with: data) { payload["style"] = style }
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            fallbackWebView?.evaluateJavaScript("window.postMessage(\(json),'*')")
        }
    }

    private func attemptProviderPlayer(refresh: Bool = false) {
        requestTask?.cancel()
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resolved = try await self.service.resolvePlayback(self.episode, refresh: refresh)
                try Task.checkCancellation()
                guard self.active else { return }
                self.providerHeaders = resolved.headers
                self.providerIsWeb = resolved.isWeb
                self.providerWebURL = resolved.webURL
                if self.episode.source == .miruro {
                    let primary = NativeStream(url: resolved.url, headers: resolved.headers, captions: resolved.captions, label: resolved.label, format: resolved.nativeFormat)
                    self.miruroAllStreams = [primary] + resolved.nativeFallbacks
                    self.miruroStreamIndex = 0
                    self.playback.servers = self.miruroAllStreams.enumerated().map { idx, stream in
                        PlaybackChoice(id: "miruro-\(idx)", title: stream.label.isEmpty ? "Server \(idx + 1)" : stream.label)
                    }
                    self.startMiruroStream(at: 0)
                } else if resolved.isWeb { self.startFallback(url: resolved.url) }
                else if self.shouldUseMediaRelay(for: resolved.url) {
                    self.filmRelay?.stop()
                    var preserveExtensions = false
                    #if DEBUG
                    preserveExtensions = PlaybackSmokeTest.source2HLS
                    #endif
                    let relay = FilmMediaRelay(origin: self.baseURL, headers: resolved.headers,
                                              preserveMediaExtensions: preserveExtensions,
                                              useSharedCookies: true)
                    relay.onQualities = { [weak self] options in
                        guard let self, self.active else { return }
                        if self.playback.qualities != options { self.playback.qualities = options }
                    }
                    self.filmRelay = relay
                    let localURL = try await relay.start(resolved.url)
                    try Task.checkCancellation()
                    self.showNativePlayer(url: localURL)
                } else { self.showNativePlayer(url: resolved.url) }
            } catch {
                guard self.active, !Task.isCancelled else { return }
                #if DEBUG
                if PlaybackSmokeTest.source2Diagnostic { PlaybackSmokeTest.diagnostic("failure", fields: ["stage": "resolve", "message": error.localizedDescription]) }
                #endif
                if refresh, let url = self.providerWebURL { self.startFallback(url: url) }
                else { self.playback.error = error.localizedDescription }
            }
        }
    }

    private func publishMiruroCaptions() {
        var list = miruroCaptions.map { PlaybackChoice(id: $0.id, title: $0.title) }
        for translated in miruroLocalCaptions.keys.filter({ $0.hasPrefix("translated:") }).sorted() {
            list.append(PlaybackChoice(id: translated, title: "Tiếng Việt · dịch tự động"))
        }
        playback.externalSubtitles = list
    }

    private func startMiruroStream(at index: Int) {
        guard active, miruroAllStreams.indices.contains(index) else { return }
        miruroStreamIndex = index
        let stream = miruroAllStreams[index]
        providerHeaders = stream.headers
        playback.server = "miruro-\(index)"
        let captions = stream.captions.enumerated().map { idx, caption in
            AetherSubtitle(id: "miruro-caption-" + String(idx), title: caption.title,
                           language: caption.language, url: caption.url, headers: caption.headers)
        }
        miruroCaptions = AetherSubtitleClient.preferred(captions)
        miruroLocalCaptions.removeAll()
        miruroSelectedCaption = nil
        miruroSelectedFile = nil
        playback.externalSubtitle = nil
        playback.canTranslateSubtitle = false
        playback.subtitleStatus = nil
        playback.subtitleBusy = false
        publishMiruroCaptions()

        miruroRelayTask?.cancel()
        filmRelay?.stop()
        filmRelay = nil

        let isDirectMP4 = stream.format == "mp4" || (stream.format.isEmpty && stream.url.pathExtension.lowercased() == "mp4")
        if isDirectMP4 {
            showNativePlayer(url: stream.url)
            autoSelectMiruroCaption()
            return
        }

        miruroRelayTask = Task { [weak self] in
            guard let self else { return }
            let relay = FilmMediaRelay(origin: stream.url, headers: stream.headers,
                                       preserveMediaExtensions: true, useSharedCookies: false,
                                       transportStreamEnvelope: true)
            relay.onQualities = { [weak self] options in
                guard let self, self.active else { return }
                if self.playback.qualities != options { self.playback.qualities = options }
            }
            self.filmRelay = relay
            do {
                let localURL = try await relay.start(stream.url, forcePlaylist: true)
                guard !Task.isCancelled, self.active else { return }
                self.showNativePlayer(url: localURL)
                self.autoSelectMiruroCaption()
            } catch {
                guard !Task.isCancelled, self.active else { return }
                self.filmRelay?.stop()
                self.filmRelay = nil
                self.showNativePlayer(url: stream.url)
                self.autoSelectMiruroCaption()
            }
        }
    }

    private func autoSelectMiruroCaption() {
        if let vi = miruroCaptions.first(where: { $0.language == "vi" }) {
            selectMiruroCaption(vi, automatic: true)
        } else if let fallback = miruroCaptions.first(where: { $0.language == "en" }) ?? miruroCaptions.first {
            selectMiruroCaption(fallback, automatic: true)
        }
    }

    private func selectMiruroCaption(_ caption: AetherSubtitle, automatic: Bool = false) {
        miruroCaptionTask?.cancel()
        miruroCaptionTask = Task { [weak self, weak player = mpvController] in
            guard let self, let player else { return }
            self.playback.subtitleBusy = true
            self.playback.subtitleStatus = "Đang tải phụ đề…"
            defer { self.playback.subtitleBusy = false }
            do {
                let file: URL
                if let cached = self.miruroLocalCaptions[caption.id] { file = cached }
                else { file = try await self.captionClient.materialize(caption) }
                guard !Task.isCancelled, self.active, player === self.mpvController else { return }
                self.miruroLocalCaptions[caption.id] = file
                self.miruroSelectedCaption = caption
                self.miruroSelectedFile = file
                player.addSubtitle(file, slot: "subtitles")
                self.playback.externalSubtitle = caption.id
                let isVietnamese = caption.language == "vi"
                self.playback.canTranslateSubtitle = !isVietnamese
                self.playback.subtitleStatus = caption.title
                if automatic, !isVietnamese {
                    self.translateMiruroCaption()
                }
            } catch {
                guard !Task.isCancelled, self.active, player === self.mpvController else { return }
                self.playback.subtitleStatus = error.localizedDescription
            }
        }
    }

    private func translateMiruroCaption() {
        guard active, episode.source == .miruro,
              let file = miruroSelectedFile, let caption = miruroSelectedCaption,
              caption.language != "vi", let player = mpvController else { return }
        miruroCaptionTask?.cancel()
        miruroCaptionTask = Task { [weak self, weak player] in
            guard let self, let player else { return }
            self.playback.subtitleBusy = true
            self.playback.subtitleStatus = "Đang dịch phụ đề sang tiếng Việt…"
            defer { self.playback.subtitleBusy = false }
            do {
                let translated = try await self.captionClient.translateToVietnamese(file) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.active, self.playback.subtitleBusy else { return }
                        self.playback.subtitleStatus = "Đang dịch sang tiếng Việt · \(Int(progress * 100))%"
                    }
                }
                guard !Task.isCancelled, self.active, player === self.mpvController else { return }
                let translatedID = "translated:" + caption.id
                self.miruroLocalCaptions[translatedID] = translated
                self.miruroSelectedFile = translated
                self.miruroSelectedCaption = nil
                self.playback.externalSubtitle = translatedID
                self.playback.canTranslateSubtitle = false
                self.publishMiruroCaptions()
                player.addSubtitle(translated, slot: "subtitles")
                self.playback.subtitleStatus = "Tiếng Việt · dịch tự động"
            } catch {
                guard !Task.isCancelled, self.active, player === self.mpvController else { return }
                self.playback.subtitleStatus = "Chưa dịch được phụ đề: " + error.localizedDescription
            }
        }
    }

    private func switchMiruroStream(to index: Int) {
        guard active, miruroAllStreams.indices.contains(index),
              !playback.pictureInPicturePending, !playback.pictureInPictureActive else { return }
        miruroCaptionTask?.cancel()
        miruroRelayTask?.cancel()
        filmRelay?.stop()
        filmRelay = nil
        miruroResumePosition = max(0, playback.currentTime)
        if let player = mpvController {
            mpvController = nil
            player.shutdown()
            player.willMove(toParent: nil)
            player.view.removeFromSuperview()
            player.removeFromParent()
        }
        startMiruroStream(at: index)
    }

    private func recoverMiruroStream(_ player: MPVPlaybackController) {
        let nextIndex = miruroStreamIndex + 1
        guard active, mpvController === player, miruroAllStreams.indices.contains(nextIndex),
              !playback.pictureInPicturePending, !playback.pictureInPictureActive else { return }
        switchMiruroStream(to: nextIndex)
    }

    private func attemptDirectPlayer() {
        if let html = service.cachedHTML(for: episodeURL), let values = HTMLParser.playerParameters(from: html) {
            startDirect(parameters: PlayerParameters(filmID: values.filmID, hash: values.hash)); return
        }
        var request = URLRequest(url: episodeURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue(AnimeService.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Referer")

        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (data, response) = try await Self.episodeSession.data(for: request)
                guard self.active, !Task.isCancelled else { return }
                guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode),
                      let html = String(data: data, encoding: .utf8),
                      let values = HTMLParser.playerParameters(from: html) else {
                    self.startFallback()
                    return
                }
                self.startDirect(parameters: PlayerParameters(filmID: values.filmID, hash: values.hash))
            } catch {
                guard self.active, !Task.isCancelled else { return }
                self.startFallback()
            }
        }
    }

    private func startDirect(parameters: PlayerParameters) {
        guard active else { return }
        loadingLabel.text = "Đang giải mã luồng phát…"
        let configuration = playerConfiguration(injectFallbackScript: false)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.customUserAgent = AnimeService.userAgent
        webView.isHidden = true
        view.addSubview(webView)
        directWebView = webView

        let hash64 = Data(parameters.hash.utf8).base64EncodedString()
        let film64 = Data(parameters.filmID.utf8).base64EncodedString()
        let key64 = Data("dm_thang_suc_vat_get_link_an_dbt".utf8).base64EncodedString()
        let html = directPlayerHTML(hash64: hash64, film64: film64, key64: key64)
        webView.loadHTMLString(html, baseURL: baseURL)

        fallbackTimer?.invalidate()
        // The direct endpoint normally answers in a few seconds. Move on quickly when
        // its player contract has changed instead of keeping the viewer on the loader.
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 9, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.startFallback() }
        }
    }

    private func startFallback(url requestedURL: URL? = nil) {
        guard active, playerController == nil, mpvController == nil,
              !playback.pictureInPictureActive, !playback.pictureInPicturePending else { return }
        deferredDirectSource = nil
        fallbackTimer?.invalidate()
        ["videoFound", "playlistFound", "iframeFound", "playerReady", "playerError", "mediaState", "pipState"].forEach {
            directWebView?.configuration.userContentController.removeScriptMessageHandler(forName: $0)
        }
        directWebView?.stopLoading()
        directWebView?.removeFromSuperview()
        directWebView = nil

        let targetURL = requestedURL ?? providerWebURL ?? episodeURL
        if let webView = fallbackWebView {
            guard fallbackLoadedURL?.absoluteString != targetURL.absoluteString else { return }
            fallbackLoadedURL = targetURL
            loadingLabel.text = "Đang mở trình phát toàn màn hình…"
            webView.isHidden = true
            loadWebPlayer(webView, url: targetURL)
            scheduleFallbackReveal(for: webView)
            return
        }

        loadingLabel.text = "Đang tải trình phát website…"
        let configuration = playerConfiguration(injectFallbackScript: true)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.customUserAgent = AnimeService.userAgent
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isHidden = true
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.backgroundColor = .black
        webView.isOpaque = false
        webView.backgroundColor = .black
        view.insertSubview(webView, belowSubview: loadingLabel)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        fallbackWebView = webView
        startVerificationTimer()
        fallbackLoadedURL = targetURL
        loadWebPlayer(webView, url: targetURL)
        scheduleFallbackReveal(for: webView)
    }

    private func loadWebPlayer(_ webView: WKWebView, url: URL) {
        webPiPConfigured = false
        resetWebPictureInPicture()
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }
            for cookie in HTTPCookieStorage.shared.cookies ?? [] {
                await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
            }
            guard self.active, self.fallbackLoadedURL == url else { return }
            webView.load(self.playerRequest(for: url))
        }
    }

    private func startVerificationTimer() {
        guard verificationTimer?.isValid != true else { return }
        verificationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.inspectVerification() }
        }
    }

    private func playerRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 40)
        request.setValue(AnimeService.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(episodeURL.absoluteString, forHTTPHeaderField: "Referer")
        return request
    }

    private func scheduleFallbackReveal(for webView: WKWebView) {
        revealTimer?.invalidate()
        revealTimer = Timer.scheduledTimer(withTimeInterval: 35, repeats: false) { [weak self, weak webView] _ in
            Task { @MainActor in
                guard let self, let webView, self.active, webView === self.fallbackWebView,
                      self.playback.loading, !self.playback.verification else { return }
                self.playback.error = "Chưa thể phát tập này. Hãy thử tải lại luồng phát."
            }
        }
    }

    private func playerConfiguration(injectFallbackScript: Bool) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        ["videoFound", "playlistFound", "iframeFound", "playerReady", "playerError", "mediaState", "pipState"].forEach {
            configuration.userContentController.add(self, name: $0)
        }
        if injectFallbackScript {
            var source = fallbackJavaScript
            if episode.source == .anime {
                // A newly opened episode starts at zero. Recreating its website
                // after a native decoder failure is the same viewing session.
                let position = websiteOwnsPlayback ? max(0, playback.currentTime > 0.1 ? playback.currentTime : nativeFallbackPosition) : 0
                let context: [String: Any] = ["episodeID": episode.id, "initialPosition": position]
                if let data = try? JSONSerialization.data(withJSONObject: context),
                   let json = String(data: data, encoding: .utf8) {
                    source = "window.__anpinimeAnimePlayback=\(json);\n" + source
                }
            }
            configuration.userContentController.addUserScript(WKUserScript(
                source: source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
        }
        return configuration
    }

    private func shouldUseMediaRelay(for url: URL) -> Bool {
        guard episode.source.isMovie else { return false }
        if providerHeaders["X-StreamC-Hash"] != nil { return true }
        if let host = url.host?.lowercased(), host.contains("streamc") { return true }
        let ext = url.pathExtension.lowercased()
        if episode.source == .film4k, (ext == "m3u8" || url.path.lowercased().contains("m3u8") || url.path.contains("/playlist")) {
            return true
        }
        if case .film4k = episode.playback {
            return ext == "m3u8" || url.path.hasSuffix("/stream/hls")
        }
        // Extensionless HLS endpoints (like /api/content/stream/hls) use FilmMediaRelay so AVPlayer receives a .m3u8 URL.
        return url.path.contains("/stream/hls") || (ext.isEmpty && url.path.lowercased().contains("hls"))
    }

    private func showNativePlayer(url: URL, referer: URL? = nil, webHandoff: Bool = false) {
        guard active, playerController == nil, mpvController == nil,
              !playback.pictureInPictureActive, !playback.pictureInPicturePending else { return }
        resetWebPictureInPicture()
        fallbackTimer?.invalidate()
        nativeSource = url
        webHandoffPending = webHandoff
        nativeStartedAt = Date()
        playback.loading = true
        playback.error = nil
        var headers = ["User-Agent": AnimeService.userAgent, "Referer": (referer ?? episodeURL).absoluteString]
        if episode.source != .anime {
            headers.merge(providerHeaders) { _, provider in provider }
            if let referer {
                headers["Referer"] = referer.absoluteString
                if let scheme = referer.scheme, let host = referer.host { headers["Origin"] = scheme + "://" + host }
            }
            // A provider's session ticket must never be forwarded to a third-party iframe/CDN.
            if url.host != baseURL.host { headers.removeValue(forKey: "X-F4K-PT") }
        }
        let cookies: [HTTPCookie] = HTTPCookieStorage.shared.cookies(for: url) ?? []
        var useMPV = true
        #if DEBUG
        // Retain the independent AVPlayer smoke test; mpv has its own MKV fixture.
        useMPV = !PlaybackSmokeTest.enabled || ProcessInfo.processInfo.arguments.contains("--mpv-playback-smoke")
        #endif
        if useMPV {
            if !cookies.isEmpty { headers["Cookie"] = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] }
            let startPosition = webHandoff ? nativeFallbackPosition : miruroResumePosition
            let controller = MPVPlaybackController(url: url, headers: headers, playback: playback, startAt: startPosition, handoffMuted: webHandoff)
            controller.onPictureInPictureEnded = { [weak self, weak controller] in
                guard let self, let controller, self.mpvController === controller else { return }
                self.finishDeferredShutdown()
            }
            let canRestoreWebsite = episode.source == .anime || fallbackWebView != nil || providerWebURL != nil
            if episode.source == .miruro {
                controller.onFailure = { [weak self, weak controller] _ in
                    Task { @MainActor in
                        if let controller { self?.recoverMiruroStream(controller) }
                    }
                }
            } else if canRestoreWebsite {
                controller.onFailure = { [weak self, weak controller] _ in
                    Task { @MainActor in
                        guard let self, let controller, self.mpvController === controller else { return }
                        self.restoreWebsiteAfterNativeFailure(reason: "decoder-failed")
                    }
                }
            }
            mpvController = controller
            addChild(controller)
            controller.view.frame = view.bounds
            controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.insertSubview(controller.view, at: 0)
            controller.didMove(toParent: self)
            loadingLabel.isHidden = true
            revealTimer?.invalidate(); verificationTimer?.invalidate()
            directWebView?.stopLoading(); directWebView?.removeFromSuperview()
            if !webHandoff {
                fallbackWebView?.evaluateJavaScript("window.postMessage({type:'AnPinimeCommand',name:'pause',value:0},'*')")
                fallbackWebView?.isHidden = true
            }
            if canRestoreWebsite, fallbackWebView != nil {
                // This handoff is optional. A URL that worked inside a website may
                // still need its custom decoder/session. Never strand that browser.
                nativeTimer?.invalidate()
                nativeTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self, weak controller] _ in
                    Task { @MainActor in
                        guard let self, let controller, self.active, self.mpvController === controller else { return }
                        if self.playback.userPaused { self.nativeStartedAt = Date(); return }
                        if !self.playback.loading, self.playback.videoWidth > 0 {
                            self.nativeTimer?.invalidate(); self.nativeTimer = nil
                            if self.webHandoffPending { self.completeWebHandoff(controller) }
                        } else if Date().timeIntervalSince(self.nativeStartedAt) > 10 {
                            self.restoreWebsiteAfterNativeFailure(reason: "handoff-timeout")
                        }
                    }
                }
            }
            return
        }
        playback.engine = "AVPlayer"
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers,
                                                  AVURLAssetHTTPCookiesKey: cookies])
        let playerItem = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: ["playable", "availableMediaCharacteristicsWithMediaSelectionOptions"])
        // Fast start for heavy high-bitrate/4K streams: start decoding with a small initial forward buffer,
        // then expand buffer once playback is active.
        playerItem.preferredForwardBufferDuration = 4.0
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = false
        player.setMediaSelectionCriteria(AVPlayerMediaSelectionCriteria(preferredLanguages: ["vi", "en"], preferredMediaCharacteristics: nil), forMediaCharacteristic: .audible)
        mediaTracksLoaded = false
        let controller = AVPlayerViewController()
        controller.player = player
        // AVPlayerViewController exposes manual PiP through its system controls;
        // there is no public startPiP() method on this controller. Hiding those
        // controls removed the only manual entry point for this backend.
        controller.showsPlaybackControls = true
        controller.delegate = self
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = UserDefaults.standard.object(forKey: "AnPinime.automaticPiP") as? Bool ?? true
        controller.videoGravity = playback.fill ? .resizeAspectFill : .resizeAspect
        player.volume = Float(playback.volume)
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(controller.view, at: 0)
        controller.didMove(toParent: self)
        playerController = controller
        applySubtitleStyle()
        if filmRelay == nil, url.pathExtension.lowercased() == "m3u8" {
            trackTask?.cancel()
            trackTask = Task { [weak self] in
                var request = URLRequest(url: url)
                headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
                guard let (data, _) = try? await Self.episodeSession.data(for: request),
                      let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U"),
                      let self, self.active, !Task.isCancelled, self.playerController?.player === player else { return }
                self.playback.qualities = FilmMediaTransform.qualities(text)
            }
        }
        loadingLabel.isHidden = true
        revealTimer?.invalidate()
        directWebView?.removeFromSuperview()
        // Do not let a hidden HTML video keep downloading alongside AVPlayer.
        fallbackWebView?.evaluateJavaScript("window.postMessage({type:'AnPinimeCommand',name:'pause',value:0},'*')")
        fallbackWebView?.isHidden = true
        player.playImmediately(atRate: Float(playback.rate))
        endedObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.active else { return }
                self.playback.playing = false
                self.playback.endCount += 1
            }
        }
        let progressTimer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateNativeState() }
        }
        nativeTimer = progressTimer
        RunLoop.main.add(progressTimer, forMode: .common)
    }

    func playerViewControllerWillStartPictureInPicture(_ controller: AVPlayerViewController) {
        guard active, controller === playerController else { return }
        playback.pictureInPicturePending = true; playback.pictureInPictureError = nil
        tracePiP("willStart")
    }
    func playerViewControllerDidStartPictureInPicture(_ controller: AVPlayerViewController) {
        guard active, controller === playerController else { return }
        playback.pictureInPictureActive = true; playback.pictureInPicturePending = false
        tracePiP("didStart")
    }
    func playerViewController(_ controller: AVPlayerViewController, failedToStartPictureInPictureWithError error: Error) {
        guard active, controller === playerController else { return }
        playback.pictureInPictureActive = false; playback.pictureInPicturePending = false
        playback.pictureInPictureError = "iOS chưa mở được PiP cho video này."
        tracePiP("failedToStart(code=\((error as NSError).code))"); finishDeferredShutdown()
    }
    func playerViewControllerDidStopPictureInPicture(_ controller: AVPlayerViewController) {
        guard active, controller === playerController else { return }
        playback.pictureInPictureActive = false; playback.pictureInPicturePending = false
        tracePiP("didStop"); finishDeferredShutdown()
    }
    func playerViewController(_ controller: AVPlayerViewController,
                              restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard active, controller === playerController else { completionHandler(false); return }
        let oldCompletion = avRestoreCompletion
        let requestID = avRestoreHandshake.begin()
        avRestoreCompletion = completionHandler
        avRestoreTimeout?.cancel()
        oldCompletion?(false)
        guard avRestoreHandshake.pendingID == requestID else { return }
        tracePiP("restoreRequested")
        avRestoreTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.completeAVRestore(requestID, success: false)
        }
        viewIfLoaded?.setNeedsLayout()
        viewIfLoaded?.layoutIfNeeded()
        acknowledgeAVRestoreIfReady()
    }
    private func acknowledgeAVRestoreIfReady() {
        guard let requestID = avRestoreHandshake.pendingID else { return }
        let source = viewIfLoaded, window = source?.window
        let scene = window?.windowScene?.activationState
        let bounds = source?.bounds ?? .zero
        let ready = NativePiPPolicy.canAcknowledgeRestore(ownerAlive: active && !shutdownRequested && !isBeingDismissed && !isMovingFromParent,
            applicationForeground: UIApplication.shared.applicationState != .background,
            sceneForeground: scene == .foregroundActive || scene == .foregroundInactive,
            sourceAttached: window != nil && window?.isHidden == false && source?.isHidden == false,
            layoutReady: bounds.width.isFinite && bounds.height.isFinite && bounds.width > 1 && bounds.height > 1)
        if ready { completeAVRestore(requestID, success: true) }
    }
    private func completeAVRestore(_ requestID: UInt64, success: Bool) {
        guard avRestoreHandshake.consume(requestID) else { return }
        let completion = avRestoreCompletion; avRestoreCompletion = nil
        avRestoreTimeout?.cancel(); avRestoreTimeout = nil
        completion?(success)
        tracePiP(success ? "restoreCompleted" : "restoreRejected")
    }
    private func tracePiP(_ event: String) {
        let backend = mpvController != nil ? "mpv" : playerController != nil ? "avplayer" : "webkit"
        var facts = ["pending": playback.pictureInPicturePending, "active": playback.pictureInPictureActive]
        if let playerController {
            facts["supported"] = AVPictureInPictureController.isPictureInPictureSupported()
            facts["frameReady"] = playerController.isReadyForDisplay
        } else if mpvController == nil {
            facts["supported"] = playback.pictureInPictureSupported
            facts["frameReady"] = !playback.loading && playback.videoWidth > 0
        }
        // WebKit and AVPlayerViewController do not expose AVKit's native
        // isPictureInPicturePossible flag. Do not substitute "supported" for it.
        PiPDiagnostics.record(event, backend: backend, sessionID: webPiPSessionID ?? piPDiagnosticSessionID,
            trigger: "system-or-user", view: viewIfLoaded, time: playback.currentTime,
            facts: facts)
    }

    private func completeWebHandoff(_ controller: MPVPlaybackController) {
        guard webHandoffPending, active, mpvController === controller,
              let webView = fallbackWebView, let frame = handoffFrame,
              UIApplication.shared.applicationState == .active else {
            restoreWebsiteAfterNativeFailure(reason: "handoff-interrupted")
            return
        }
        nativeTimer?.invalidate()
        nativeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self, weak controller] _ in
            Task { @MainActor in
                guard let self, let controller, self.active, self.mpvController === controller, self.webHandoffPending else { return }
                self.restoreWebsiteAfterNativeFailure(reason: "handoff-frame-timeout")
            }
        }
        webView.callAsyncJavaScript("return window.__anpinimePauseForHandoff && window.__anpinimePauseForHandoff()",
                                   arguments: [:], in: frame, in: .page) { [weak self, weak controller] result in
            guard let self, let controller, self.active, self.mpvController === controller,
                  self.webHandoffPending else { return }
            self.nativeTimer?.invalidate(); self.nativeTimer = nil
            guard case .success(let value) = result, let state = value as? [String: Any],
                  let time = state["time"] as? Double, time.isFinite,
                  UIApplication.shared.applicationState == .active else {
                self.restoreWebsiteAfterNativeFailure(reason: "handoff-frame-unavailable")
                return
            }
            self.webHandoffPending = false
            self.nativeFallbackPosition = max(0, time)
            controller.perform("seek", value: max(0, time))
            if self.playback.userPaused { controller.perform("pause", value: 0) }
            controller.finishHandoff()
            webView.isHidden = true
        }
    }

    private func restoreWebsiteAfterNativeFailure(reason: String) {
        guard active, let controller = mpvController else { return }
        if let nativeSource { failedNativeSources.insert(nativeSource) }
        // A rotating signed URL must not restart the same failed handoff. The
        // website retains this episode until the user explicitly reloads it.
        websiteOwnsPlayback = true
        webHandoffPending = false
        handoffFrame = nil
        animeWebCaptionTask?.cancel()
        animeWebCaptions = []
        playback.externalSubtitles = []
        playback.externalSubtitle = nil
        filmRelay?.stop(); filmRelay = nil
        let paused = playback.userPaused
        let position = playback.currentTime > 0.1 ? playback.currentTime : nativeFallbackPosition
        nativeTimer?.invalidate(); nativeTimer = nil
        controller.onFailure = nil
        mpvController = nil
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        controller.shutdown()
        playback.error = nil; playback.loading = true; playback.buffering = false; playback.playing = false
        playback.pictureInPictureActive = false; playback.pictureInPicturePending = false
        playback.pictureInPictureSupported = false; playback.pictureInPictureError = nil
        playback.audioTracks = []; playback.subtitleTracks = []; playback.engine = "WebKit"
        playback.userPaused = paused
        #if DEBUG
        if PlaybackSmokeTest.animeSmoke { PlaybackSmokeTest.diagnostic("anime-native-failed", fields: ["reason": reason]) }
        #endif
        if let webView = fallbackWebView {
            webView.isHidden = false
            startVerificationTimer()
            webView.evaluateJavaScript("window.__anyanimeFocusPlayer && window.__anyanimeFocusPlayer()")
            if position > 0 { perform("seek", value: position) }
            perform(paused ? "pause" : "play", value: 0)
            configureWebPictureInPicture()
            scheduleFallbackReveal(for: webView)
            #if DEBUG
            if PlaybackSmokeTest.animeSmoke { PlaybackSmokeTest.diagnostic("anime-web-restored", fields: ["reusedWebsite": true]) }
            #endif
        } else {
            startFallback()
        }
    }

    private func updateNativeState() {
        guard active, let player = playerController?.player, let item = player.currentItem else { return }
        if item.status == .failed || (playback.loading && Date().timeIntervalSince(nativeStartedAt) > 25) {
            if let nativeSource { failedNativeSources.insert(nativeSource) }
            nativeTimer?.invalidate()
            if let endedObserver { NotificationCenter.default.removeObserver(endedObserver); self.endedObserver = nil }
            player.pause()
            playerController?.willMove(toParent: nil)
            playerController?.view.removeFromSuperview()
            playerController?.removeFromParent()
            playerController = nil
            playback.loading = true
            playback.buffering = false
            playback.audioTracks = []; playback.subtitleTracks = []
            if episode.source.isMovie && !providerRefreshAttempted {
                providerRefreshAttempted = true
                resumeAfterRefresh = playback.currentTime
                attemptProviderPlayer(refresh: true)
                return
            }
            if let webView = fallbackWebView {
                webView.isHidden = false
                perform("play", value: 0)
                scheduleFallbackReveal(for: webView)
            } else if !episode.source.isMovie || providerWebURL != nil { startFallback() }
            else { playback.error = "Không phát được định dạng video này từ nguồn đã chọn." }
            return
        }
        if item.status == .readyToPlay && !mediaTracksLoaded {
            mediaTracksLoaded = true
            loadMediaTracks(item)
            if resumeAfterRefresh > 0 {
                player.seek(to: CMTime(seconds: resumeAfterRefresh, preferredTimescale: 600))
                resumeAfterRefresh = 0
            }
        }
        let duration = item.duration.seconds
        let time = player.currentTime().seconds
        if duration.isFinite { playback.duration = max(0, duration) }
        if time.isFinite { playback.currentTime = max(0, time) }
        playback.playing = player.timeControlStatus == .playing
        playback.buffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if player.timeControlStatus == .playing || time > 0 {
            playback.loading = false; playback.error = nil
            if time > 2.5, item.preferredForwardBufferDuration < 12.0 {
                item.preferredForwardBufferDuration = 16.0
                player.automaticallyWaitsToMinimizeStalling = true
            }
        }
        #if DEBUG
        PlaybackSmokeTest.record(time: time, backend: "native", size: view.bounds.size, playback: playback)
        #endif
    }

    private func loadMediaTracks(_ item: AVPlayerItem) {
        let generation = UUID().uuidString
        audioOptions = [:]; subtitleOptions = [:]
        if let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) {
            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            playback.audioTracks = group.options.enumerated().map { index, option in
                let id = "\(generation)-audio-\(index)"
                audioOptions[id] = option
                if option == selected { playback.audioTrack = id }
                return PlaybackChoice(id: id, title: option.displayName)
            }
        }
        if let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            playback.subtitleTrack = "off"
            playback.subtitleTracks = [.init(id: "off", title: "Tắt phụ đề")] + group.options.enumerated().map { index, option in
                let id = "\(generation)-subtitle-\(index)"
                subtitleOptions[id] = option
                if option == selected { playback.subtitleTrack = id }
                return PlaybackChoice(id: id, title: option.displayName)
            }
        }
    }

    private func selectAnimeWebCaption(_ caption: AetherSubtitle) {
        animeWebCaptionTask?.cancel()
        animeWebCaptionTask = Task { [weak self, weak player = mpvController] in
            guard let self, let player else { return }
            do {
                let file = try await self.captionClient.materialize(caption)
                guard !Task.isCancelled, self.active, player === self.mpvController else { return }
                player.addSubtitle(file, slot: "subtitles")
                self.playback.externalSubtitle = caption.id
            } catch {
                guard !Task.isCancelled, self.active, player === self.mpvController else { return }
                self.playback.subtitleStatus = error.localizedDescription
            }
        }
    }

    private func chooseOption(_ kind: String, id: String) {
        guard active else { return }
        if episode.source == .miruro, kind == "server", id.hasPrefix("miruro-"),
           let idx = Int(id.dropFirst(7)), miruroAllStreams.indices.contains(idx) {
            if idx != miruroStreamIndex || playback.error != nil {
                switchMiruroStream(to: idx)
            }
            return
        }
        if let mpvController {
            if episode.source == .anime, kind == "subtitles",
               let caption = animeWebCaptions.first(where: { $0.id == id }) {
                selectAnimeWebCaption(caption)
                return
            }
            if episode.source == .anime, kind == "subtitles" {
                animeWebCaptionTask?.cancel()
                playback.externalSubtitle = nil
            }
            if episode.source == .miruro, kind == "subtitles" {
                if let caption = miruroCaptions.first(where: { $0.id == id }) {
                    selectMiruroCaption(caption, automatic: false)
                    return
                }
                if let file = miruroLocalCaptions[id] {
                    miruroCaptionTask?.cancel()
                    miruroSelectedFile = file
                    miruroSelectedCaption = nil
                    playback.externalSubtitle = id
                    playback.canTranslateSubtitle = false
                    mpvController.addSubtitle(file, slot: "subtitles")
                    return
                }
                miruroCaptionTask?.cancel()
                miruroSelectedCaption = nil
                miruroSelectedFile = nil
                playback.externalSubtitle = nil
                playback.canTranslateSubtitle = false
            }
            mpvController.choose(kind, id: id)
            return
        }
        guard let item = playerController?.player?.currentItem else {
            let payload = ["type": "AnPinimeCommand", "name": "track", "kind": kind, "id": id]
            if let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) {
                fallbackWebView?.evaluateJavaScript("window.postMessage(\(json),'*')")
            }
            return
        }
        if kind == "quality", let option = playback.qualities.first(where: { $0.id == id }) {
            item.preferredPeakBitRate = option.bandwidth
            item.preferredMaximumResolution = CGSize(width: option.width, height: option.height)
            playback.quality = id
            return
        }
        let characteristic: AVMediaCharacteristic = kind == "audio" ? .audible : .legible
        guard let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic) else { return }
        if kind == "subtitles", id == "off" { item.select(nil, in: group); playback.subtitleTrack = "off" }
        else if kind == "subtitles", let option = subtitleOptions[id], group.options.contains(option) {
            item.select(option, in: group); playback.subtitleTrack = id
        } else if kind == "audio", let option = audioOptions[id], group.options.contains(option) {
            item.select(option, in: group); playback.audioTrack = id
        }
    }

    private func applySubtitleStyle() {
        let attributes: [String: Any] = [
            kCMTextMarkupAttribute_RelativeFontSize as String: playback.subtitleSize,
            kCMTextMarkupAttribute_BackgroundColorARGB as String: [playback.subtitleBackground ? 0.7 : 0.0, 0.0, 0.0, 0.0]
        ]
        if let rule = AVTextStyleRule(textMarkupAttributes: attributes) { playerController?.player?.currentItem?.textStyleRules = [rule] }
    }

    private static func isAdFrameURL(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return false }
        let blocked = ["doubleclick", "googlesyndication", "adservice", "popads", "exoclick", "juicyads", "trafficjunky", "propellerads", "adsterra"]
        return blocked.contains(where: { host.contains($0) })
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard active else { return }
        // Filter out obvious ad iframes while keeping legitimate player iframes active for PiP/native handoff.
        if message.webView === fallbackWebView, !message.frameInfo.isMainFrame, Self.isAdFrameURL(message.frameInfo.request.url) { return }
        switch message.name {
        case "videoFound", "playlistFound":
            #if DEBUG
            if PlaybackSmokeTest.webOnly { return }
            #endif
            guard let sourceWebView = message.webView else { return }
            let details = message.body as? [String: String] ?? [:]
            let inline = message.name == "playlistFound" ? details["playlist"] : nil
            let value = (message.body as? String) ?? details["url"]
            let url = value.flatMap { resolvedURL(from: $0) }
            if inline != nil {
                guard episode.source == .anime, sourceWebView === fallbackWebView,
                      details["sessionID"] == webPiPSessionID,
                      FilmMediaTransform.validAbsolutePlaylist(inline!) else { return }
            } else if url == nil { return }
            guard playerController == nil, mpvController == nil, !preparingNative,
                  !playback.pictureInPictureActive, !playback.pictureInPicturePending else { return }
            if let url, failedNativeSources.contains(url) { return }
            let fromWebsite = sourceWebView === fallbackWebView
            guard sourceWebView === directWebView || fromWebsite,
                  !fromWebsite || !websiteOwnsPlayback else { return }
            let referer = message.frameInfo.request.url ?? episodeURL
            let captionRows: [[String: Any]] = details["captions"].flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
            guard captionRows.count <= 100 else { return }
            let captions: [(AetherSubtitle, Bool)] = captionRows.compactMap { row in
                guard let raw = row["url"] as? String, let url = URL(string: raw),
                      url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { return nil }
                let name = row["label"] as? String ?? "Phụ đề"
                let language = row["language"] as? String ?? name
                return (AetherSubtitle(title: name, language: language, url: url, headers: ["Referer": referer.absoluteString]),
                        row["selected"] as? Bool == true)
            }
            guard UIApplication.shared.applicationState == .active else {
                if !fromWebsite, let url { deferredDirectSource = (url, referer) }
                return
            }
            preparingNative = true
            nativeFallbackPosition = fromWebsite ? playback.currentTime : 0
            let websiteURL = fromWebsite ? fallbackLoadedURL : nil
            let selectedFrame = message.frameInfo
            nativePrepareTask?.cancel()
            nativePrepareTask = Task { [weak self, weak sourceWebView] in
                guard let self, let sourceWebView else { return }
                defer { self.preparingNative = false }
                let cookies = await withCheckedContinuation { continuation in
                    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
                }
                guard !Task.isCancelled, self.active, sourceWebView === self.directWebView || sourceWebView === self.fallbackWebView,
                      !fromWebsite || self.fallbackLoadedURL == websiteURL,
                      self.mpvController == nil, self.playerController == nil,
                      !self.playback.pictureInPictureActive, !self.playback.pictureInPicturePending,
                      UIApplication.shared.applicationState == .active else { return }
                for cookie in cookies { HTTPCookieStorage.shared.setCookie(cookie) }
                guard self.episode.source == .anime else {
                    if let url { self.showNativePlayer(url: url, referer: referer) }
                    return
                }
                do {
                    let selectedCaption = captions.first(where: { $0.1 })?.0
                    let selectedFile: URL?
                    if let selectedCaption { selectedFile = try await self.captionClient.materialize(selectedCaption) }
                    else { selectedFile = nil }
                    try Task.checkCancellation()
                    let playbackURL: URL
                    if let inline {
                        let root = referer.deletingLastPathComponent().appendingPathComponent("anpinime-blob.m3u8")
                        guard let mediaURL = FilmMediaTransform.firstAbsolutePlaylistURL(inline) else { throw AnimeServiceError.invalidResponse }
                        var headers = ["User-Agent": AnimeService.userAgent, "Referer": referer.absoluteString]
                        let hostCookies = HTTPCookieStorage.shared.cookies(for: mediaURL) ?? []
                        if !hostCookies.isEmpty { headers["Cookie"] = HTTPCookie.requestHeaderFields(with: hostCookies)["Cookie"] }
                        let relay = FilmMediaRelay(origin: referer, headers: headers,
                                                   preserveMediaExtensions: true, useSharedCookies: false,
                                                   scopedHeaderHost: mediaURL.host)
                        self.filmRelay = relay
                        playbackURL = try await relay.start(root, inlinePlaylist: inline)
                    } else if let url, url.pathExtension.lowercased() == "m3u8" || url.path.lowercased().contains("hls") || details["provenance"] == "playlist" {
                        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
                        request.setValue(AnimeService.userAgent, forHTTPHeaderField: "User-Agent")
                        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
                        let (data, response) = try await Self.animeManifestSession.data(for: request)
                        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                              data.count <= 1_048_576, let text = String(data: data, encoding: .utf8),
                              text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U"),
                              let finalURL = http.url, ["http", "https"].contains(finalURL.scheme?.lowercased() ?? "") else {
                            throw AnimeServiceError.invalidResponse
                        }
                        var headers = ["User-Agent": AnimeService.userAgent, "Referer": referer.absoluteString]
                        let hostCookies = HTTPCookieStorage.shared.cookies(for: finalURL) ?? []
                        if !hostCookies.isEmpty { headers["Cookie"] = HTTPCookie.requestHeaderFields(with: hostCookies)["Cookie"] }
                        let relay = FilmMediaRelay(origin: referer, headers: headers, preserveMediaExtensions: true,
                                                   useSharedCookies: false, scopedHeaderHost: finalURL.host)
                        self.filmRelay = relay
                        playbackURL = try await relay.start(finalURL, forcePlaylist: true)
                    } else if let url { playbackURL = url }
                    else { throw AnimeServiceError.invalidURL }
                    guard !Task.isCancelled, self.active, self.mpvController == nil,
                          (sourceWebView === self.directWebView || sourceWebView === self.fallbackWebView),
                          (!fromWebsite || self.fallbackLoadedURL == websiteURL), UIApplication.shared.applicationState == .active else {
                        self.filmRelay?.stop(); self.filmRelay = nil; return
                    }
                    self.handoffFrame = fromWebsite ? selectedFrame : nil
                    self.animeWebCaptions = captions.map { $0.0 }
                    self.playback.externalSubtitles = self.animeWebCaptions.map { PlaybackChoice(id: $0.id, title: $0.title) }
                    self.showNativePlayer(url: playbackURL, referer: referer, webHandoff: fromWebsite)
                    if let selectedCaption, let selectedFile, let player = self.mpvController {
                        player.addSubtitle(selectedFile, slot: "subtitles")
                        self.playback.externalSubtitle = selectedCaption.id
                    }
                } catch {
                    self.filmRelay?.stop(); self.filmRelay = nil
                }
            }
        case "iframeFound":
            guard let value = message.body as? String, let url = resolvedURL(from: value) else { return }
            startFallback(url: url)
        case "playerReady":
            guard playerController == nil, mpvController == nil else { return }
            fallbackWebView?.isHidden = false
            if !webPiPConfigured { configureWebPictureInPicture() }
        case "mediaState":
            guard message.webView === fallbackWebView, playerController == nil, mpvController == nil,
                  let state = message.body as? [String: Any] else { return }
            if let time = state["time"] as? Double, time.isFinite { playback.currentTime = max(0, time) }
            if let duration = state["duration"] as? Double, duration.isFinite { playback.duration = max(0, duration) }
            playback.playing = (state["paused"] as? Bool) == false && (state["ready"] as? Bool) == true
            playback.buffering = !playback.userPaused && (state["buffering"] as? Bool) == true
            if let tracks = state["tracks"] as? [String: Any] {
                func choices(_ name: String) -> [PlaybackChoice] {
                    (tracks[name] as? [[String: String]] ?? []).compactMap { row in
                        guard let id = row["id"], let title = row["title"] else { return nil }
                        return PlaybackChoice(id: id, title: title)
                    }
                }
                playback.audioTracks = choices("audio")
                playback.subtitleTracks = choices("subtitles")
                playback.audioTrack = tracks["audioID"] as? String ?? ""
                playback.subtitleTrack = tracks["subtitleID"] as? String ?? "off"
            }
            playback.videoWidth = (state["videoWidth"] as? Double) ?? 0
            playback.videoHeight = (state["videoHeight"] as? Double) ?? 0
            playback.engine = "WebKit"
            updateWebPictureInPicture(state, frame: message.frameInfo)
            if (state["ready"] as? Bool) == true || playback.currentTime > 0 && playback.duration > 0 {
                let wasLoading = playback.loading
                playback.loading = false; playback.verification = false; playback.error = nil
                revealTimer?.invalidate()
                fallbackWebView?.isHidden = false
                if wasLoading {
                    perform("rate", value: playback.rate)
                    perform("volume", value: playback.volume)
                    perform("fit", value: playback.fill ? 1 : 0)
                    perform("subtitleStyle", value: 0)
                }
            }
            let ended = (state["ended"] as? Bool) == true
            if ended && !webEnded { playback.endCount += 1 }
            webEnded = ended
            #if DEBUG
            PlaybackSmokeTest.record(time: playback.currentTime, backend: "web", size: view.bounds.size, playback: playback,
                                     videoSize: CGSize(width: (state["videoWidth"] as? Double) ?? 0,
                                                       height: (state["videoHeight"] as? Double) ?? 0))
            #endif
        case "pipState":
            guard message.webView === fallbackWebView, playerController == nil, mpvController == nil,
                  let state = message.body as? [String: String],
                  let requestID = state["requestID"], let sessionID = state["sessionID"],
                  sessionID == webPiPSessionID else { return }
            if state["status"] == "pending", requestID == webHomeRequestID,
               !playback.pictureInPictureActive, !playback.pictureInPicturePending, !playback.userPaused {
                beginWebPiPRequest(requestID, sessionID: sessionID)
            }
            guard requestID == webPiPRequestID else { return }
            if state["status"] == "active" {
                webPiPTimeout?.invalidate(); webPiPTimeout = nil
                playback.pictureInPictureActive = true
                playback.pictureInPicturePending = false
                playback.pictureInPictureError = nil
                tracePiP("didStart")
            } else if state["status"] == "stopped" {
                finishWebPictureInPictureRequest(requestID, sessionID: sessionID, stopped: true)
            } else if state["status"] == "error" {
                finishWebPictureInPictureRequest(requestID, sessionID: sessionID,
                    error: webPictureInPictureError(state["error"] ?? ""))
            }
        case "playerError":
            if let detail = message.body as? String { print("[AnPinime Player] \(detail)") }
            startFallback()
        default:
            break
        }
    }

    private func resolvedURL(from value: String) -> URL? {
        let cleaned = value
            .replacingOccurrences(of: "\\/", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: cleaned, relativeTo: fallbackLoadedURL ?? episodeURL)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === fallbackWebView, mpvController == nil, playerController == nil else { return }
        webPiPConfigured = false
        resetWebPictureInPicture()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === fallbackWebView else { return }
        webView.evaluateJavaScript("window.__anyanimeFocusPlayer && window.__anyanimeFocusPlayer()")
        inspectVerification()
    }

    private func inspectVerification() {
        guard active, playerController == nil, let webView = fallbackWebView, !webView.isLoading else { return }
        webView.evaluateJavaScript(WebsiteSession.pageInspection) { [weak self, weak webView] result, _ in
            guard let self, self.active, let webView, let page = result as? [String: Any], let html = page["html"] as? String else { return }
            let challenge = HTMLParser.containsVerification(html)
            if challenge && (page["interactive"] as? Bool) == true {
                self.playback.verification = true
                webView.isHidden = false
                webView.scrollView.isScrollEnabled = true
            } else if !challenge && self.playback.verification {
                self.playback.verification = false
                webView.scrollView.isScrollEnabled = false
                webView.scrollView.contentInsetAdjustmentBehavior = .never
                self.scheduleFallbackReveal(for: webView)
                webView.evaluateJavaScript("window.__anyanimeFocusPlayer && window.__anyanimeFocusPlayer()")
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard active, (error as NSError).code != NSURLErrorCancelled else { return }
        if webView === directWebView { startFallback() }
        else { playback.error = "Không tải được video: \(error.localizedDescription)" }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url,
           url.host == episodeURL.host { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let normalized = message.folding(options: .diacriticInsensitive, locale: Locale(identifier: "vi_VN")).lowercased()
        if normalized.contains("neu ban khong the truy cap animevietsub") {
            completionHandler()
            return
        }
        let alert = UIAlertController(title: "Trình phát", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    private func directPlayerHTML(hash64: String, film64: String, key64: String) -> String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width"><style>body{background:#000}</style>
        <script src="/js/pako.min.js"></script></head><body><script>
        function bytes(s){return Uint8Array.from(atob(s),c=>c.charCodeAt(0));}
        function source(data){
          function item(v){
            if(Array.isArray(v))return item(v[0]);
            return typeof v==='string'?v:(v&&(v.file||v.src||v.url));
          }
          try {
            var j=JSON.parse(data), first=j.sources&&j.sources[0], nested=j.player&&j.player.sources&&j.player.sources[0];
            var direct=item(first)||item(nested)||item(j.data)||item(j.link)||item(j.file)||item(j.url);
            if(direct)return {kind:/\\.(?:m3u8|mp4)(?:$|[?#])/i.test(direct)||/\\/hls\\b/i.test(direct)?'video':'iframe',url:direct};
          } catch(e) {}
          var doc=new DOMParser().parseFromString(data,'text/html');
          var media=doc.querySelector('video[src],source[src]');
          if(media)return {kind:'video',url:media.getAttribute('src')};
          var frame=doc.querySelector('iframe[src]');
          if(frame)return {kind:'iframe',url:frame.getAttribute('src')};
          var normalized=data.replace(/\\\\\\//g,'/');
          var m=normalized.match(/https?:\\/\\/[^\\s\"'<>]+\\.(?:m3u8|mp4)(?:[^\\s\"'<>]*)?/i);
          if(m)return {kind:'video',url:m[0]};
          var u=normalized.match(/https?:\\/\\/[^\\s\"'<>]+/i);
          return u&&{kind:'iframe',url:u[0]};
        }
        async function decryptPayload(encrypted, keyText){
          var digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(keyText));
          var key=await crypto.subtle.importKey('raw',digest,{name:'AES-CBC'},false,['decrypt']);
          var clean=encrypted.replace(/-/g,'+').replace(/_/g,'/'); while(clean.length%4)clean+='=';
          var raw=bytes(clean);
          var clear=await crypto.subtle.decrypt({name:'AES-CBC',iv:raw.slice(0,16)},key,raw.slice(16));
          try{return pako.inflateRaw(new Uint8Array(clear),{to:'string'});}catch(e){return new TextDecoder().decode(clear);}
        }
        async function start(){
          try {
            if(typeof pako==='undefined'){await new Promise((ok,no)=>{var s=document.createElement('script');s.src='https://cdnjs.cloudflare.com/ajax/libs/pako/2.1.0/pako.min.js';s.onload=ok;s.onerror=no;document.head.appendChild(s);});}
            var hash=atob('\(hash64)'), id=atob('\(film64)'), defaultKey=atob('\(key64)');
            var endpoints=['/ajax/player?v=2019a','/ajax/player'];
            var value='', ok=false, lastStatus=0;
            for(var i=0;i<endpoints.length;i++){
              var form=new FormData(); form.append('link',hash); form.append('id',id);
              var response=await fetch(endpoints[i],{method:'POST',headers:{'X-Requested-With':'XMLHttpRequest'},body:form,credentials:'include'});
              lastStatus=response.status;
              if(response.ok){ value=await response.text(); if(value&&value.trim()){ ok=true; break; } }
            }
            if(!ok) throw Error('HTTP '+lastStatus);
            var text=value, encrypted='', extraKey='';
            try {
              var json=JSON.parse(value);
              if(json.playTech&&typeof json.playTech==='string')extraKey=json.playTech;
              var candidate=json.data||json.link||json.html;
              if(typeof candidate==='string'&&!/^https?:\\/\\//i.test(candidate.trim())&&!/^\\s*[\\[{<]/.test(candidate)){
                encrypted=candidate;
              }
            } catch(e) {
              if(!/^https?:\\/\\//i.test(value.trim())&&!/^\\s*[\\[{<]/.test(value)) encrypted=value;
            }
            if(encrypted){
              var keys=extraKey?[extraKey,defaultKey]:[defaultKey];
              var decrypted=null;
              for(var k=0;k<keys.length;k++){
                try{ decrypted=await decryptPayload(encrypted,keys[k]); break; }catch(e){}
              }
              if(decrypted) text=decrypted;
            }
            var found=source(text); if(!found||!found.url) throw Error('Không tìm thấy nguồn video');
            var absolute=new URL(found.url,location.href).href;
            window.webkit.messageHandlers[found.kind==='video'?'videoFound':'iframeFound'].postMessage(absolute);
          } catch(e) {
            var detail=(e&&e.message)||String(e);
            document.title='ERROR:'+detail;
            window.webkit.messageHandlers.playerError.postMessage(detail);
          }
        }
        // The local script tag is blocking: pako is ready here, or start() immediately
        // loads the CDN fallback. Polling for three seconds only slowed failure recovery.
        start();
        </script></body></html>
        """
    }

    private var fallbackJavaScript: String {
        """
        (function(){
          if(window.__anyanimeInstalled)return; window.__anyanimeInstalled=true;
          // StreamC publishes a JW setup with advertising + autostart:false.
          // Keep its access checks and sealed playlist loader; alter only player presentation.
          var streamC=/(^|\\.)streamc\\.xyz$/i.test(location.hostname);
          function wrapJW(factory){
            if(!streamC||typeof factory!=='function'||factory.__anpinimeWrapped)return factory;
            var wrapped=new Proxy(factory,{apply:function(target,receiver,args){
              var api=Reflect.apply(target,receiver,args);
              if(api&&typeof api.setup==='function'&&!api.__anpinimeSetup){
                var setup=api.setup;
                api.setup=function(config){
                  var clean=Object.assign({},config,{autostart:true});delete clean.advertising;
                  return setup.call(this,clean);
                };
                api.__anpinimeSetup=true;
              }
              return api;
            }});
            Object.defineProperty(wrapped,'__anpinimeWrapped',{value:true});return wrapped;
          }
          if(streamC){
            var currentJW=wrapJW(window.jwplayer),descriptor=Object.getOwnPropertyDescriptor(window,'jwplayer');
            if(!descriptor||descriptor.configurable){
              Object.defineProperty(window,'jwplayer',{configurable:true,get:function(){return currentJW;},set:function(value){currentJW=wrapJW(value);}});
            }else if(typeof window.jwplayer==='function'){window.jwplayer=wrapJW(window.jwplayer);}
          }
          function needsWebsiteDecoder(){return streamC&&window.streamAccess&&window.streamAccess.shouldUseSealedLoader&&window.streamAccess.shouldUseSealedLoader()===true;}
          var hidden=['.Adv','.ad-center','.ads','.advertisement','[class*="ads"]','[class*="banner"]','[id*="ads"]','iframe[src*="ads"]','.popup','.modal-backdrop','.header-ads-pc','.Adv.ad-center-header','header','footer','.footer','.header','.sidebar','.breadcrumb','.comments','.film-info','.heading-film','.list-episode-box','.server-list','.film-thumb','.film-desc','.film-buttons','.category-heading','.block-film','nav','.navbar','.menu'];
          var viewport=document.querySelector('meta[name="viewport"]');
          if(!viewport){viewport=document.createElement('meta');viewport.name='viewport';(document.head||document.documentElement).appendChild(viewport);}
          viewport.content='width=device-width,initial-scale=1,maximum-scale=1,viewport-fit=cover';
          var reportedFrames={};
          var activeVideo=null;
          var reportedSources={};
          var automaticPiP=false;
          // Native supplies this context only for anime, once per selected
          // episode. Movie providers keep their existing startup behavior.
          var animeContext=window.__anpinimeAnimePlayback;
          var animeStartPending=!!(animeContext&&typeof animeContext.episodeID==='string'&&animeContext.episodeID);
          var animeResumeActions=new WeakSet();
          function initializeAnimePosition(v){
            if(!animeStartPending||!v||v.readyState<1||isAdvertisement(v)||pipActive(v)||pipPending(v))return;
            var position=Number(animeContext.initialPosition)||0;
            try{if(v.currentTime!==position)v.currentTime=Math.max(0,position);animeStartPending=false;}catch(e){}
          }
          function resumeText(el){
            return String(el.textContent||el.value||'').normalize('NFD').replace(/[\\u0300-\\u036f]/g,'').toLowerCase().replace(/đ/g,'d').replace(/\\s+/g,' ').trim();
          }
          function declineAnimeResume(){
            if(!animeContext||!animeContext.episodeID)return;
            document.querySelectorAll('#avs-resume-btn-no,button,a,[role="button"],input[type="button"]').forEach(function(button){
              if(button.disabled||animeResumeActions.has(button)||! /^(?:(?:xem|phat|xem lai) )?tu dau$/.test(resumeText(button)))return;
              var popup=button.parentElement;
              for(var depth=0;popup&&popup!==document.body&&depth<7;depth++,popup=popup.parentElement){
                var text=resumeText(popup);
                if(text.length>2500)break;
                if(popup.id!=='avs-resume-overlay'&&!/he thong ghi nhan.*(?:tung|da) xem anime/.test(text))continue;
                // Use the website's original From Beginning action: it clears
                // only this video's saved prompt and releases its own overlay.
                animeResumeActions.add(button);
                button.click();
                return;
              }
            });
          }
          \(WebPictureInPictureScript.core)
          function hidePauseOverlays(root){
            function keepMedia(el){
              Array.from(el.children).forEach(function(child){
                if(child.matches('video,.jw-captions'))return;
                if(child.querySelector('video,.jw-captions'))keepMedia(child);
                else important(child,'display','none');
              });
            }
            root.querySelectorAll('.jw-overlays').forEach(keepMedia);
            root.querySelectorAll('.jw-overlays > *,[class*="pause-ad"],[class*="pauseAd"],[id*="pause-ad"],.jw-ad-container,.vast-blocker').forEach(function(el){
              if(!el.matches('.jw-captions')&&!el.querySelector('.jw-captions')&&!el.querySelector('video'))important(el,'display','none');
            });
          }
          var playerSelectors='#media-player,.player-container,.watching_player,#player,.jwplayer,[class*="video-player"],[class*="player-wrap"]';
          var adSelectors='.ad,.ads,.advertisement,.video-ad,.ima-ad-container,.jw-ad,.jw-flag-ads,.vjs-ad-playing,[data-ad="true"]';
          function send(name,value){try{window.webkit.messageHandlers[name].postMessage(value);}catch(e){}}
          function adURL(s){return /(?:doubleclick|googlesyndication|popads|adservice|vast|\\/ads?[\\/.?]|[?&](?:ad|preroll)=)/i.test(s||'');}
          function playerAPI(v){
            try{
              if(typeof window.jwplayer!=='function')return null;
              var container=v&&v.closest('.jwplayer');
              var api=container?window.jwplayer(container.id):window.jwplayer();
              if(!api||typeof api.getPlaylistItem!=='function')return null;
              if(!api.__aaAdEvents&&api.on){
                api.__aaAdEvents=true;
                ['adPlay','adImpression','adStarted'].forEach(function(e){api.on(e,function(){api.__aaAdActive=true;});});
                ['adBreakEnd','adComplete','adSkipped','adError'].forEach(function(e){api.on(e,function(){api.__aaAdActive=false;});});
              }
              return api;
            }catch(e){return null;}
          }
          function contentSources(api){
            try{
              var item=api&&api.getPlaylistItem();if(!item)return [];
              return (item.sources||[]).map(function(x){return x.file||x.src;}).concat(item.file||[])
                .filter(function(x){return typeof x==='string'&&x&&!adURL(x);})
                .map(function(x){return new URL(x,location.href).href;});
            }catch(e){return [];}
          }
          function captionData(v){
            var tracks=[],api=playerAPI(v),item=null,current=-1;
            try{
              item=api&&api.getPlaylistItem();
              if(api&&api.getCurrentCaptions)current=Number(api.getCurrentCaptions());
              var captionIndex=0;
              (item&&item.tracks||[]).forEach(function(t){
                if(!/^(captions|subtitles)$/i.test(t.kind||''))return;
                captionIndex++;
                var src=t.file||t.src;if(!src)return;
                tracks.push({url:new URL(src,location.href).href,label:t.label||t.srclang||'Phụ đề',language:t.srclang||t.language||'',selected:current===captionIndex});
              });
              if(v)v.querySelectorAll('track[src]').forEach(function(t){
                if(!/^(captions|subtitles)$/i.test(t.kind||''))return;
                tracks.push({url:new URL(t.src,location.href).href,label:t.label||t.srclang||'Phụ đề',language:t.srclang||'',selected:!!(t.track&&t.track.mode==='showing')});
              });
            }catch(e){}
            return JSON.stringify(tracks.slice(0,100));
          }
          function isAdvertisement(v){
            if(!v||v.closest(adSelectors)||adURL(mediaURL(v)))return true;
            var api=playerAPI(v);
            return !!(api&&api.__aaAdActive);
          }
          function contentURL(v){
            var s=mediaURL(v),api=playerAPI(v),sources=contentSources(api);
            // A JW preroll can replace currentSrc on the SAME video element.
            // Only its actual playlist item is eligible for the native handoff.
            if(api){
              if(!sources.length)return '';
              if(sources.indexOf(s)>=0)return s;
              return sources.find(function(x){return /\\.m3u8(?:[?#]|$)/i.test(x);})||sources[0];
            }
            if(isAdvertisement(v))return '';
            return /^https?:/i.test(s)&&!adURL(s)?s:'';
          }
          function reportSource(v){
            var raw=mediaURL(v);
            if(animeContext&&typeof window.fetch==='function'&&/^blob:/i.test(raw)&&v.readyState>=2&&v.videoWidth>0&&!isAdvertisement(v)&&!v.__aaBlobProbe){
              v.__aaBlobProbe=raw;
              window.fetch(raw).then(function(response){return response.blob();}).then(function(blob){
                if(blob.size>1048576||v!==activeVideo||mediaURL(v)!==raw)return null;
                return blob.text();
              }).then(function(text){
                if(typeof text==='string'&&text.trim().indexOf('#EXTM3U')===0&&v===activeVideo&&mediaURL(v)===raw)
                  send('playlistFound',{playlist:text,sessionID:pipContext(v).sessionID,captions:captionData(v)});
              }).catch(function(){});
            }
            if(needsWebsiteDecoder()||pipActive(v)||pipPending(v))return;
            var s=contentURL(v),provenance=s===mediaURL(v)&&v.readyState>=2&&v.videoWidth>0?'media':'playlist';
            if(/^https?:/i.test(s)&&(!reportedSources[s]||(reportedSources[s]==='playlist'&&provenance==='media'))){reportedSources[s]=provenance;send('videoFound',{url:s,referer:location.href,provenance:provenance,captions:captionData(v)});}
          }
          function tryPlay(v){
            if(!v||v.__aaUserPaused||!v.paused)return;
            var p=v.play();if(p&&p.catch)p.catch(function(){state();});
          }
          function important(el,key,value){if(el&&(el.style.getPropertyValue(key)!==value||el.style.getPropertyPriority(key)!=='important'))el.style.setProperty(key,value,'important');}
          function hideAccessNotices(){
            var candidates=document.querySelectorAll('p,span,small,a,.alert,.notice,.message,.warning,[class*="notice"],[class*="warning"],[class*="notify"]');
            candidates.forEach(function(el){
              var text=String(el.innerText||el.textContent||'').toLowerCase();
              var notice=text.indexOf('nếu bạn không thể truy cập animevietsub')>=0||text.indexOf('neu ban khong the truy cap animevietsub')>=0;
              if(notice&&text.length<500)important(el,'display','none');
            });
          }
          function challenge(){return /just a moment|attention required.*cloudflare|xác minh an toàn|xác minh bảo mật|verify you are human|checking your browser/i.test(document.title)||!!document.querySelector('#challenge-form,.cf-turnstile,iframe[src*="challenges.cloudflare.com"],#verification:not([hidden])');}
          function trackState(v){
            var api=playerAPI(v),audio=[],subs=[{id:'off',title:'Tắt'}],aid='',sid='off';
            try{
              if(api&&api.getAudioTracks){
                audio=api.getAudioTracks().map(function(t,i){return {id:String(i),title:t.name||t.label||t.language||('Âm thanh '+(i+1))};});aid=String(api.getCurrentAudioTrack());
              }else if(v.audioTracks){Array.from(v.audioTracks).forEach(function(t,i){audio.push({id:String(i),title:t.label||t.language||('Âm thanh '+(i+1))});if(t.enabled)aid=String(i);});}
              if(api&&api.getCaptionsList){
                api.getCaptionsList().forEach(function(t,i){if(i>0)subs.push({id:String(i),title:t.label||t.language||('Phụ đề '+i)});});
                var selected=api.getCurrentCaptions();if(selected>0)sid=String(selected);
              }else if(v.textTracks){Array.from(v.textTracks).forEach(function(t,i){if(t.kind==='metadata'||t.kind==='chapters')return;subs.push({id:String(i),title:t.label||t.language||('Phụ đề '+(i+1))});if(t.mode==='showing')sid=String(i);});}
            }catch(e){}
            return {audio:audio,subtitles:subs,audioID:aid,subtitleID:sid};
          }
          function chooseTrack(v,kind,id){
            var api=playerAPI(v),index=Number(id);
            if(kind==='audio'){
              if(api&&api.setCurrentAudioTrack)api.setCurrentAudioTrack(index);
              else if(v.audioTracks)Array.from(v.audioTracks).forEach(function(t,i){t.enabled=i===index;});
            }else if(kind==='subtitles'){
              if(api&&api.setCurrentCaptions)api.setCurrentCaptions(id==='off'?0:index);
              else if(v.textTracks)Array.from(v.textTracks).forEach(function(t,i){if(t.kind!=='metadata'&&t.kind!=='chapters')t.mode=id!=='off'&&i===index?'showing':'disabled';});
            }
          }
          function styleSubtitles(v,s){
            if(!s)return;
            function color(c){return /^#[a-f0-9]{8}$/i.test(c)?'#'+c.slice(3)+c.slice(1,3):'#ffffffff';}
            var font=['Arial','Helvetica','Times New Roman','Menlo'].indexOf(s.font)>=0?s.font:'Arial';
            var size=Math.max(18,Math.min(80,Number(s.size)||42)),margin=Math.max(0,Math.min(150,Number(s.margin)||0));
            var align=['left','center','right'].indexOf(s.alignment)>=0?s.alignment:'center';
            var css=document.getElementById('anpinime-sub-style');if(!css){css=document.createElement('style');css.id='anpinime-sub-style';document.head.appendChild(css);}
            css.textContent='video::cue{font-family:"'+font+'";font-size:'+size+'px;color:'+color(s.foreground)+';background-color:'+color(s.background)+';text-shadow:1px 1px 2px '+color(s.outline)+'}'+
              '.jw-captions{bottom:'+margin+'px!important;text-align:'+align+'!important}.jw-text-track-cue{font-family:"'+font+'"!important;font-size:'+size+'px!important;color:'+color(s.foreground)+'!important;background-color:'+color(s.background)+'!important;text-shadow:1px 1px 2px '+color(s.outline)+'!important}';
            var api=playerAPI(v);if(api&&api.setCaptions)api.setCaptions({fontFamily:font,fontSize:size,color:color(s.foreground),backgroundColor:color(s.background),edgeStyle:'uniform'});
            if(v.textTracks)Array.from(v.textTracks).forEach(function(t){Array.from(t.cues||[]).forEach(function(c){c.snapToLines=false;c.line=Math.max(5,95-margin/3);c.align=align;});});
          }
          function state(){
            var v=activeVideo;if(!v||isAdvertisement(v))return;
            initializeAnimePosition(v);
            reportSource(v);
            var now=Date.now();if(v.__aaLastTime!==v.currentTime){v.__aaLastTime=v.currentTime;v.__aaAdvancedAt=now;}
            var advancing=now-(v.__aaAdvancedAt||now)<1200;
            var pc=pipContext(v);syncPiP(v,pc);
            send('mediaState',{pipSessionID:pc.sessionID,pipRequestID:pc.requestID,pipError:pc.error,pipSupported:supportsPiP(v),pipActive:pipActive(v),pipPending:pipPending(v),time:isFinite(v.currentTime)?v.currentTime:0,duration:isFinite(v.duration)?v.duration:0,paused:v.paused,buffering:!v.paused&&v.readyState<3&&!advancing,ready:v.readyState>=2||(v.currentTime>0&&v.videoWidth>0),ended:v.ended,videoWidth:v.videoWidth||0,videoHeight:v.videoHeight||0,tracks:trackState(v)});
          }
          var homeCommand=null;
          window.__anpinimeArmHomePiP=function(sessionID,requestID,enabled){
            if(!activeVideo||pipContext(activeVideo).sessionID!==sessionID)return false;
            automaticPiP=enabled===true;
            homeCommand=automaticPiP&&requestID?{name:'pipAutomatically',sessionID:sessionID,requestID:requestID}:null;
            return true;
          };
          // Execute in the playing document as it becomes hidden. By the time
          // the UIKit background notification arrives WebKit may be suspended.
          document.addEventListener('visibilitychange',function(){
            var v=activeVideo,command=homeCommand;
            if(!document.hidden||!automaticPiP||!command||!v||v.paused||v.ended||v.__aaUserPaused||
               !v.videoWidth||v.readyState<2||isAdvertisement(v)||command.sessionID!==pipContext(v).sessionID)return;
            homeCommand=null;
            requestPiP(v,command);state();
          });
          window.__anpinimeHandoffCommand=function(name,value){
            var v=activeVideo;if(!v||isAdvertisement(v))return;
            if(name==='pause'){v.__aaUserPaused=true;v.pause();}
            else if(name==='play'){v.__aaUserPaused=false;tryPlay(v);}
            else if(name==='seek'&&isFinite(v.duration))v.currentTime=Math.max(0,Math.min(Number(value)||0,v.duration));
            else if(name==='rate')v.playbackRate=Math.max(0.25,Math.min(Number(value)||1,3));
            else if(name==='volume')v.volume=Math.max(0,Math.min(Number(value)||0,1));
          };
          window.__anpinimePauseForHandoff=function(){
            var v=activeVideo;if(!v||isAdvertisement(v))return null;
            var time=Number(v.currentTime)||0;v.pause();return {time:time};
          };
          window.__anpinimeRequestPiP=function(command){requestPiP(activeVideo,command);state();};
          window.addEventListener('message',function(event){
            var c=event.data;if(!c||c.type!=='AnPinimeCommand')return;
            // The player container can be ready before its video is created.
            // Retain the preference for that later video instead of dropping it.
            if(c.name==='automaticPiP')automaticPiP=c.value===1;
            var v=activeVideo;
            if(v&&isAdvertisement(v))v=null;
            if(v){
              try{
                switch(c.name){
                  case 'pip':requestPiP(v,c);break;
                  case 'pipAutomatically':requestPiP(v,c);break;
                  case 'pipStop':stopPiP(v);break;
                  case 'track':chooseTrack(v,c.kind,c.id);break;
                  case 'subtitleStyle':styleSubtitles(v,c.style);break;
                  case 'play':v.__aaUserPaused=false;tryPlay(v);break;
                  case 'pause':v.__aaUserPaused=true;v.pause();break;
                  case 'seek':if(isFinite(v.duration)){v.currentTime=Math.max(0,Math.min(Number(c.value)||0,v.duration));if(animeContext)animeStartPending=false;}break;
                  case 'rate':v.playbackRate=Math.max(0.25,Math.min(Number(c.value)||1,3));break;
                  case 'volume':v.volume=Math.max(0,Math.min(Number(c.value)||0,1));break;
                  case 'fit':v.__anpinimeFill=c.value===1;important(v,'object-fit',v.__anpinimeFill?'cover':'contain');break;
                }
                state();
              }catch(e){}
            }
            document.querySelectorAll('iframe').forEach(function(f){try{f.contentWindow.postMessage(c,'*');}catch(e){}});
          });
          function hideChrome(){
            hidden.forEach(function(s){try{document.querySelectorAll(s).forEach(function(e){important(e,'display','none');});}catch(e){}});
            hideAccessNotices();
            important(document.documentElement,'margin','0'); important(document.documentElement,'padding','0');
            important(document.documentElement,'background','#000'); important(document.documentElement,'overflow','hidden');
            important(document.body,'margin','0'); important(document.body,'padding','0');
            important(document.body,'background','#000'); important(document.body,'overflow','hidden');
          }
          function isolate(el){
            if(!el)return false; hideChrome();
            var node=el;
            while(node&&node!==document.body){
              var parent=node.parentElement;
              if(!parent)break;
              Array.prototype.forEach.call(parent.children,function(sibling){if(sibling!==node)important(sibling,'display','none');});
              important(parent,'display','block'); important(parent,'visibility','visible'); important(parent,'opacity','1');
              important(parent,'position','static'); important(parent,'width','100%'); important(parent,'height','100%');
              important(parent,'margin','0'); important(parent,'padding','0'); important(parent,'transform','none');
              node=parent;
            }
            important(el,'display','block'); important(el,'visibility','visible'); important(el,'opacity','1');
            important(el,'position','fixed'); important(el,'inset','0'); important(el,'width','100vw');
            important(el,'height','100vh'); important(el,'max-width','none'); important(el,'max-height','none');
            important(el,'margin','0'); important(el,'padding','0'); important(el,'z-index','2147483647');
            important(el,'background','#000'); important(el,'transform','none'); important(el,'box-sizing','border-box'); important(el,'min-width','0'); important(el,'min-height','0');
            send('playerReady','ready'); return true;
          }
          function mediaURL(v){
            var s=v.currentSrc||v.getAttribute('src')||'';
            if(!s){var source=v.querySelector('source[src]');if(source)s=source.getAttribute('src')||'';}
            try{return s?new URL(s,location.href).href:'';}catch(e){return '';}
          }
          function watch(v){
            if(!v||isAdvertisement(v))return false;
            activeVideo=v;
            if(pipActive(v)||pipPending(v)){state();return true;}
            var jw=v.closest('.jwplayer');
            if(jw){
              isolate(jw);hidePauseOverlays(jw);
              jw.querySelectorAll('.jw-controls,.jw-display,.jw-logo,.jw-overlays').forEach(function(el){if(!el.querySelector('.jw-captions'))important(el,'display','none');});
              important(v,'width','100%');important(v,'height','100%');important(v,'object-position','center');
            }else{isolate(v);}
            important(v,'object-fit',v.__anpinimeFill?'cover':'contain'); v.setAttribute('playsinline','');v.controls=false;v.disablePictureInPicture=false;
            if(!v.__aa){
              v.__aa=true;
              ['playing','loadedmetadata','loadeddata','canplay','pause','waiting','ended','durationchange','timeupdate','enterpictureinpicture','leavepictureinpicture','webkitpresentationmodechanged'].forEach(function(name){v.addEventListener(name,function(){if(v===activeVideo)state();});});
              ['loadedmetadata','canplay'].forEach(function(name){v.addEventListener(name,function(){tryPlay(v);});});
              tryPlay(v);
            }
            state();
            return true;
          }
          function usefulFrame(frame){
            var src=frame.getAttribute('src')||'';
            if(!src||/^(?:about:blank|javascript:)/i.test(src)||adURL(src)||frame.closest(adSelectors))return false;
            var rect=frame.getBoundingClientRect();
            return rect.width>=240&&rect.height>=120;
          }
          function focus(){
            if(!window.document||!document.documentElement)return false;
            if(activeVideo&&(pipActive(activeVideo)||pipPending(activeVideo))){state();return true;}
            if(challenge())return false;
            declineAnimeResume();
            // Read the content playlist before filtering ad-marked video elements.
            // A preroll may use the same element, or the movie video may not exist yet.
            var api=playerAPI(null),sources=contentSources(api);
            var configured=sources.find(function(x){return /\\.m3u8(?:[?#]|$)/i.test(x);})||sources[0];
            if(!animeContext&&!needsWebsiteDecoder()&&configured&&!reportedSources[configured]){
              reportedSources[configured]='playlist';send('videoFound',{url:configured,referer:location.href,provenance:'playlist'});
            }
            hideChrome();
            var videos=Array.prototype.filter.call(document.querySelectorAll('video'),function(v){
              if(isAdvertisement(v))return false;
              for(var node=v;node&&node!==document.body;node=node.parentElement){
                var style=getComputedStyle(node);if(style.display==='none'||style.visibility==='hidden')return false;
              }
              return true;
            });
            var inPlayer=videos.filter(function(v){return !!v.closest(playerSelectors);});
            var video=inPlayer[0]||(videos.length===1?videos[0]:null);
            if(video)return watch(video);
            activeVideo=null;
            var player=document.querySelector(playerSelectors);
            var frames=Array.prototype.filter.call(document.querySelectorAll('iframe[src]'),usefulFrame);
            frames.sort(function(a,b){var ar=a.getBoundingClientRect(),br=b.getBoundingClientRect();return br.width*br.height-ar.width*ar.height;});
            var playerFrames=frames.filter(function(f){return !!f.closest(playerSelectors);});
            var frame=playerFrames[0]||(frames.length===1?frames[0]:null);
            if(frame){
              isolate(frame);
              if(window===window.top){
                try{var url=new URL(frame.getAttribute('src'),location.href).href;if(!reportedFrames[url]){reportedFrames[url]=true;send('iframeFound',url);}}catch(e){}
              }
              return true;
            }
            return player?isolate(player):false;
          }
          window.__anyanimeFocusPlayer=focus;
          function install(){
            if(!document.documentElement){setTimeout(install,20);return;}
            focus();
            new MutationObserver(function(){focus();}).observe(document.documentElement,{childList:true,subtree:true,attributes:true,attributeFilter:['src','class']});
            var tries=0,timer=setInterval(function(){focus();if(++tries>120)clearInterval(timer);},500);
            setInterval(state,500);
            setTimeout(function(){if(activeVideo||challenge())return;var b=document.querySelector('.jw-icon-playback,.play-btn,[class*="play-button"],button[aria-label*="Play"],button[title*="Play"]');if(b)b.click();focus();},1800);
          }
          if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',install,{once:true});else install();
        })();
        """
    }
}

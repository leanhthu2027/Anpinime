import UIKit
import WebKit
import AVFoundation

private final class AetherPlayerMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: AetherPlayerViewController?
    @MainActor func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }
}

/// One website decoder beneath CinemaPlayerView. The provider resolves the
/// pinned media route; this controller never reads or promotes a stream URL.
@MainActor
final class AetherPlayerViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private let episode: Episode
    private let service: AnimeService
    private let playback: PlaybackState
    private var webView: WKWebView!
    private var origin: URL?
    private var mediaPath: String?
    private var requestTask: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var pipDeadline: Task<Void, Never>?
    private var pipWaitingMessage: String?
    private var pip = WebPiPSessionState()
    private var currentSession: String?
    private var currentArea = 0.0
    private var currentPlaying = false
    private var currentReady = false
    private var initialPlaySubmitted = false
    private var desiredPaused: Bool
    private var ended = false
    private var live = true
    private var shutdownRequested = false
    private var retainedForPiP: AetherPlayerViewController?
    private let diagnosticID = UUID().uuidString

    init(episode: Episode, service: AnimeService, playback: PlaybackState) {
        self.episode = episode; self.service = service; self.playback = playback
        desiredPaused = playback.userPaused
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let proxy = AetherPlayerMessageProxy(); proxy.owner = self
        for name in ["mediaState", "pipState", "bridgeError"] { configuration.userContentController.add(proxy, name: name) }
        configuration.userContentController.addUserScript(WKUserScript(source: AetherPlayerScript.javascript,
            injectionTime: .atDocumentStart, forMainFrameOnly: false))
        webView = WKWebView(frame: view.bounds, configuration: configuration)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = self; webView.uiDelegate = self
        view.addSubview(webView)
        playback.engine = "Aether · WebKit"
        playback.websiteControlsAvailable = true; playback.websiteControlsVisible = false
        playback.supportsAdvancedSubtitles = false
        playback.command = { [weak self] name, value in self?.perform(name, value: value) }
        playback.chooseOption = { [weak self] kind, id in self?.choose(kind, id: id) }
        playback.importSubtitle = nil
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        NotificationCenter.default.addObserver(self, selector: #selector(endExplicitly), name: Notification.Name("AnPinime.sourceWillChange"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(endExplicitly), name: Notification.Name("AnPinime.libraryWillChange"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(endExplicitly), name: Notification.Name("AnPinime.playerWillStart"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foreground), name: UIApplication.didBecomeActiveNotification, object: nil)
        requestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let resolved = try await self.service.resolvePlayback(self.episode)
                try Task.checkCancellation()
                guard self.live, resolved.isWeb, let origin = AetherDomainPolicy.origin(resolved.url) else { throw AetherError.invalidPage }
                self.origin = origin
                self.mediaPath = resolved.url.path
                self.webView.load(URLRequest(url: resolved.url, timeoutInterval: 30))
                self.startDeadline()
            } catch {
                guard self.live, !Task.isCancelled else { return }
                self.playback.loading = false; self.playback.error = error.localizedDescription
            }
        }
    }

    func shutdown(force: Bool = false) {
        guard live else { return }
        // Dismantling a pending, inactive player is an explicit close: end its
        // document rather than self-retaining an abandoned platform request.
        // An already active PiP presentation keeps its owning WebView alive.
        if !force, pip.active {
            shutdownRequested = true; retainedForPiP = self
            return
        }
        live = false
        requestTask?.cancel(); deadline?.cancel(); pipDeadline?.cancel()
        NotificationCenter.default.removeObserver(self)
        send(["name": "endSession"])
        webView?.pauseAllMediaPlayback(completionHandler: nil)
        webView?.stopLoading(); webView?.navigationDelegate = nil; webView?.uiDelegate = nil
        for name in ["mediaState", "pipState", "bridgeError"] { webView?.configuration.userContentController.removeScriptMessageHandler(forName: name) }
        webView?.loadHTMLString("", baseURL: nil)
        retainedForPiP = nil
    }
    @objc private func endExplicitly() { shutdown(force: true) }
    @objc private func foreground() {
        guard live else { return }
        // Read state again; never reload the document, change decoder or stop PiP.
        send(["name": "automaticPiP", "value": UserDefaults.standard.object(forKey: "AnPinime.automaticPiP") as? Bool == false ? 0 : 1])
    }

    private func perform(_ name: String, value: Double) {
        guard live else { return }
        if name == "play" { desiredPaused = false }
        if name == "pause" { desiredPaused = true }
        if name == "websiteControls" { showWebsiteControls(value == 1); return }
        if ["subtitleStyle", "subtitleSize", "subtitleBackground"].contains(name) { showWebsiteControls(true); return }
        if name == "pip" { requestPiP(); return }
        // A stop command is acknowledged ONLY by the matching JS stopped event.
        // Clearing active immediately would destroy WebKit during its animation.
        if name == "pipStop" {
            pipDeadline?.cancel(); pipDeadline = nil
            send(["name": "pipStop", "sessionID": pip.sessionID ?? currentSession ?? ""])
            return
        }
        send(["name": name, "value": value, "sessionID": currentSession ?? ""])
    }
    private func choose(_ kind: String, id: String) {
        guard ["audio", "subtitles"].contains(kind) else { showWebsiteControls(true); return }
        let tracks = kind == "audio" ? playback.audioTracks : playback.subtitleTracks
        guard tracks.contains(where: { $0.id == id }) else { return }
        send(["name": "track", "kind": kind, "id": id, "sessionID": currentSession ?? ""])
    }
    private func showWebsiteControls(_ visible: Bool) {
        playback.websiteControlsVisible = visible
        if visible { playback.loading = false; playback.error = nil }
        send(["name": "websiteControls", "value": visible ? 1 : 0])
    }
    private func send(_ fields: [String: Any]) {
        var payload = fields; payload["type"] = "AnPinimeCommand"
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let text = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.postMessage(\(text),'*')")
    }

    private func requestPiP() {
        let requestID = UUID().uuidString
        guard currentPlaying, let sessionID = pip.begin(requestID: requestID) else {
            playback.pictureInPictureError = "Video hiện tại chưa sẵn sàng cho PiP. Thử nút PiP trong điều khiển Aether."
            return
        }
        pipWaitingMessage = nil
        publishPiP(); trace("startRequested", trigger: "manual")
        send(["name": "pip", "sessionID": sessionID, "requestID": requestID])
        pipDeadline?.cancel()
        pipDeadline = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, self.live else { return }
            guard self.pip.sessionID == sessionID, self.pip.requestID == requestID, self.pip.pending else { return }
            // A slow system presentation may still complete. Keep its owner
            // until WebKit acknowledges success/rejection/cancellation.
            self.pipWaitingMessage = "iOS chưa xác nhận PiP. Hãy đợi hoặc đóng trình phát để dừng phiên này."
            self.publishPiP()
        }
    }
    private func publishPiP() {
        playback.pictureInPictureSupported = pip.supported
        playback.pictureInPicturePending = pip.pending; playback.pictureInPictureActive = pip.active
        if !pip.pending { pipWaitingMessage = nil }
        playback.pictureInPictureError = pip.error.isEmpty ? pipWaitingMessage : "Aether chưa mở được PiP cho video này. Website hoặc iOS có thể không cho phép; thử nút PiP trong điều khiển gốc."
        if pip.active || pip.pending { retainedForPiP = self }
        else {
            pipDeadline?.cancel(); pipDeadline = nil; retainedForPiP = nil
            if shutdownRequested { shutdown(force: true) }
        }
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard live, message.webView === webView, origin != nil else { return }
        if message.name == "mediaState", let state = message.body as? [String: Any], let session = state["pipSessionID"] as? String {
            let playing = state["paused"] as? Bool == false && state["ready"] as? Bool == true
            let ready = state["ready"] as? Bool == true && state["removed"] as? Bool != true
            let area = state["area"] as? Double ?? 0
            if let currentSession, session != currentSession {
                if pip.active || pip.pending { return }
                let replacesCurrent = state["replacesSession"] as? String == currentSession
                if !replacesCurrent {
                    if currentPlaying, !playing || area <= currentArea { return }
                    if !playing, state["pipActive"] as? Bool != true, currentReady || !ready { return }
                }
            }
            let changed = currentSession != session
            var next = pip
            guard next.snapshot(state) else { return }
            pip = next; currentSession = session; currentArea = area; currentPlaying = playing; currentReady = ready
            if changed || state["removed"] as? Bool == true {
                initialPlaySubmitted = false; ended = false
                playback.currentTime = 0; playback.duration = 0
                playback.audioTracks = []; playback.subtitleTracks = []; playback.audioTrack = ""; playback.subtitleTrack = "off"
                if changed { send(["name": "owner", "sessionID": session]) }
            }
            if let value = state["time"] as? Double, value.isFinite { playback.currentTime = max(0, value) }
            if let value = state["duration"] as? Double, value.isFinite { playback.duration = max(0, value) }
            playback.playing = playing; playback.buffering = state["buffering"] as? Bool == true
            playback.videoWidth = state["videoWidth"] as? Double ?? 0; playback.videoHeight = state["videoHeight"] as? Double ?? 0
            if initialPlaySubmitted {
                if let rate = state["rate"] as? Double, rate.isFinite, rate >= 0.25, rate <= 3 { playback.rate = rate }
                if let volume = state["volume"] as? Double, volume.isFinite { playback.volume = min(1, max(0, volume)) }
            }
            if let tracks = state["tracks"] as? [String: Any] {
                func choices(_ key: String) -> [PlaybackChoice] {
                    (tracks[key] as? [[String: String]] ?? []).compactMap { row in
                        guard let id = row["id"], let title = row["title"] else { return nil }
                        return PlaybackChoice(id: id, title: title)
                    }
                }
                playback.audioTracks = choices("audio"); playback.subtitleTracks = choices("subtitles")
                playback.audioTrack = tracks["audioID"] as? String ?? ""; playback.subtitleTrack = tracks["subtitleID"] as? String ?? "off"
            }
            if state["ready"] as? Bool == true {
                deadline?.cancel(); playback.loading = false; playback.error = nil
                if !initialPlaySubmitted {
                    initialPlaySubmitted = true
                    perform("rate", value: playback.rate); perform("volume", value: playback.volume)
                    if !desiredPaused { perform("play", value: 0) }
                } else { desiredPaused = state["paused"] as? Bool == true; playback.userPaused = desiredPaused }
            }
            let hasEnded = state["ended"] as? Bool == true
            if hasEnded, !ended { playback.endCount += 1 }; ended = hasEnded
            publishPiP()
        } else if message.name == "pipState", let state = message.body as? [String: String] {
            pip.event(state); trace(state["status"] ?? "event", trigger: "website"); publishPiP()
        } else if message.name == "bridgeError", let state = message.body as? [String: String], state["sessionID"] == currentSession {
            showWebsiteControls(true)
        }
    }

    private func startDeadline() {
        deadline?.cancel()
        deadline = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 35_000_000_000)
            guard !Task.isCancelled, let self, self.live, !self.playback.playing else { return }
            // Server selection, a gesture or a site's access challenge may be
            // required. Show its functional panel rather than an endless spinner.
            self.showWebsiteControls(true)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.targetFrame?.isMainFrame != false {
            guard let url = action.request.url, let origin, url.path == mediaPath,
                  AetherDomainPolicy.permitsNavigation(url, pinnedOrigin: origin), !pip.active, !pip.pending else { decisionHandler(.cancel); return }
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard response.isForMainFrame else { decisionHandler(.allow); return }
        guard let url = response.response.url, let origin, url.path == mediaPath,
              AetherDomainPolicy.permitsNavigation(url, pinnedOrigin: origin) else { decisionHandler(.cancel); return }
        if let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
            deadline?.cancel(); showWebsiteControls(true)
            if http.statusCode != 403 { playback.error = "Máy chủ Anpinime VIP trả HTTP \(http.statusCode). Hãy thử lại hoặc chọn nguồn khác." }
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard live else { return }
        send(["name": "websiteControls", "value": playback.websiteControlsVisible ? 1 : 0]); foreground()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        guard live, (error as? URLError)?.code != .cancelled else { return }
        deadline?.cancel(); playback.loading = false
        playback.error = "Không tải được video Anpinime VIP. Hãy thử lại hoặc kiểm tra tên miền trong Cài đặt."
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard live else { return }
        pip = WebPiPSessionState(); publishPiP(); playback.loading = false
        playback.error = "Trình phát Anpinime VIP đã dừng. Hãy thử tải lại video."
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Popup navigation cannot create a second player. Original server,
        // subtitle and translation menus remain in this WebView.
        return nil
    }
    private func trace(_ event: String, trigger: String) {
        PiPDiagnostics.record(event, backend: "webkit", sessionID: pip.sessionID ?? diagnosticID, trigger: trigger, view: webView,
            time: playback.currentTime, facts: ["supported": pip.supported, "active": pip.active, "pending": pip.pending])
    }
}

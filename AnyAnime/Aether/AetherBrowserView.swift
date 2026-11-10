import SwiftUI
import WebKit
import AVFoundation

struct AetherBrowserView: View {
    @StateObject private var session = AetherBrowserSession()
    @AppStorage("AnPinime.automaticPiP") private var automaticPiP = true
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { session.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!session.canGoBack).accessibilityLabel("Quay lại trong Aether")
                Text("Tìm kiếm và thể loại trong Aether").font(.caption).frame(maxWidth: .infinity)
                Button { session.requestPiP() } label: { Image(systemName: "pip.enter") }
                    .disabled(!session.pip.supported || session.pip.pending || session.pip.active)
                    .accessibilityLabel("Mở cửa sổ nổi Aether").accessibilityIdentifier("aether.pip")
                Button("Kết thúc phiên") { session.shutdown() }
                    .font(.caption).accessibilityIdentifier("aether.end-session")
            }.padding(10)
            if session.loading { ProgressView().padding(4) }
            if let error = session.error {
                Text(error).font(.footnote).multilineTextAlignment(.center).padding()
            }
            if session.ended || session.error != nil { Button("Mở Aether") { session.open(force: true) }.padding(.bottom, 8) }
            if !session.pip.error.isEmpty {
                Text("Video này chưa mở được PiP. Hãy thử nút PiP ngay trong player Aether khi video đang phát. Tính năng tùy thuộc website và iOS.")
                    .font(.footnote).padding(8)
            }
            AetherWebSurface(session: session)
                .id(session.browserGeneration)
                .accessibilityIdentifier("aether.browser")
        }
        .onAppear { session.open(); session.setAutomaticPiP(automaticPiP) }
        .onChange(of: automaticPiP) { session.setAutomaticPiP($0) }
    }
}

private struct AetherWebSurface: UIViewRepresentable {
    let session: AetherBrowserSession
    func makeUIView(context: Context) -> WKWebView { session.webView }
    func updateUIView(_ view: WKWebView, context: Context) { }
    // The session, rather than a temporary SwiftUI/tab host, owns the browser.
}

private final class AetherMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: AetherBrowserSession?
    @MainActor func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.userContentController(userContentController, didReceive: message)
    }
}

@MainActor
final class AetherBrowserSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var canGoBack = false
    @Published private(set) var ended = false
    @Published private(set) var browserGeneration = UUID()
    @Published private(set) var pip = WebPiPSessionState()
    private(set) var webView: WKWebView!
    private let resolver: AetherDomainResolver
    private var pinnedOrigin: URL?
    private var opening: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var pipDeadline: Task<Void, Never>?
    private var navigationGeneration = UUID()
    private var hasOpened = false
    private var backObservation: NSKeyValueObservation?
    private var ending = false
    private var automatic = true
    private var retainedForPiP: AetherBrowserSession?
    private var time = 0.0
    private var playing = false
    private let diagnosticID = UUID().uuidString

    init(resolver: AetherDomainResolver = .shared) {
        self.resolver = resolver
        super.init()
        createBrowser()
        NotificationCenter.default.addObserver(self, selector: #selector(sourceWillChange), name: Notification.Name("AnPinime.sourceWillChange"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sourceWillChange), name: Notification.Name("AnPinime.libraryWillChange"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(returnedToForeground), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    private func createBrowser() {
        // Only an explicit new session gets a new browsing history. Fullscreen,
        // subtitle changes, tabs and PiP continue using the original WKWebView.
        backObservation = nil
        webView?.navigationDelegate = nil; webView?.uiDelegate = nil
        for name in ["pipState", "mediaState"] { webView?.configuration.userContentController.removeScriptMessageHandler(forName: name) }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        // Respect the site's own Play gesture; do not autoplay/replace decoders.
        let proxy = AetherMessageProxy(); proxy.owner = self
        for name in ["pipState", "mediaState"] { config.userContentController.add(proxy, name: name) }
        config.userContentController.addUserScript(WKUserScript(source: Self.observerJavaScript,
            injectionTime: .atDocumentStart, forMainFrameOnly: false))
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self; webView.uiDelegate = self
        backObservation = webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.canGoBack = self.pinnedOrigin != nil && self.webView.canGoBack
            }
        }
        browserGeneration = UUID()
        // Keep WebKit's mobile UA, website controls, caption renderer and storage.
    }

    deinit { NotificationCenter.default.removeObserver(self); opening?.cancel(); deadline?.cancel(); pipDeadline?.cancel() }

    func open(force: Bool = false) {
        guard opening == nil, !pip.active, !pip.pending else { return }
        guard pinnedOrigin == nil || force else { return } // SwiftUI updates never reload the player.
        // A retry is an explicit new session, not a mid-playback domain swap.
        shutdown()
        loading = true; error = nil; ended = false
        opening = Task { @MainActor [weak self, resolver] in
            do {
                let selection = try await resolver.resolve(force: force)
                try Task.checkCancellation()
                guard let self else { return }
                if self.hasOpened { self.createBrowser() }
                self.hasOpened = true
                self.ending = false
                self.pinnedOrigin = selection.origin
                if selection.needsVerification { self.error = "Aether yêu cầu xác minh. Hãy làm theo hướng dẫn ngay trong trang." }
                self.webView.load(URLRequest(url: selection.origin))
                self.startNavigationDeadline()
                self.opening = nil
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.error = error.localizedDescription; self.loading = false; self.opening = nil
            }
        }
    }

    func setAutomaticPiP(_ value: Bool) { automatic = value; send(["name": "automaticPiP", "value": value ? 1 : 0]) }
    func goBack() { guard !pip.active, !pip.pending else { return }; webView.goBack() }

    func requestPiP() {
        let request = UUID().uuidString
        guard playing, let session = pip.begin(requestID: request) else { return }
        retainedForPiP = self
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        trace("startRequested", trigger: "manual")
        send(["name": "pip", "requestID": request, "sessionID": session])
        pipDeadline?.cancel()
        pipDeadline = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pip.fail(requestID: request, sessionID: session, reason: "timeout")
            self.finishPiPUpdate()
        }
    }

    func shutdown() {
        opening?.cancel(); opening = nil; deadline?.cancel(); deadline = nil
        pipDeadline?.cancel(); pipDeadline = nil; navigationGeneration = UUID()
        send(["name": "endSession"])
        webView?.stopLoading()
        // Unload only on an explicit end/source change/retry, never on PiP/tab transitions.
        let hadOrigin = pinnedOrigin != nil
        ending = true; pinnedOrigin = nil
        if hadOrigin { webView?.loadHTMLString("", baseURL: nil) }
        pip = WebPiPSessionState(); retainedForPiP = nil
        playing = false; time = 0; loading = false; canGoBack = false; ended = true; error = nil
    }
    @objc private func sourceWillChange() { shutdown() }
    @objc private func returnedToForeground() { setAutomaticPiP(automatic) }

    private func send(_ fields: [String: Any]) {
        var payload = fields; payload["type"] = "AnPinimeCommand"
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.postMessage(\(json),'*')")
    }

    private func startNavigationDeadline() {
        deadline?.cancel(); loading = true
        let generation = UUID(); navigationGeneration = generation
        deadline = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled, let self, self.navigationGeneration == generation else { return }
            self.loading = false; self.error = "Aether chưa tải xong. Bạn có thể thử lại hoặc chọn tên miền khác trong Cài đặt."
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if ending, action.request.url?.absoluteString == "about:blank" { decisionHandler(.allow); return }
        if action.targetFrame?.isMainFrame != false {
            guard let url = action.request.url, let pinnedOrigin,
                  AetherDomainPolicy.permitsNavigation(url, pinnedOrigin: pinnedOrigin) else {
                decisionHandler(.cancel); return
            }
            if pip.active || pip.pending { decisionHandler(.cancel); return }
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame, !ending {
            guard let url = response.response.url, let pinnedOrigin,
                  AetherDomainPolicy.permitsNavigation(url, pinnedOrigin: pinnedOrigin) else {
                deadline?.cancel(); loading = false; error = "Aether chuyển đến địa chỉ ngoài phiên đã chọn. Hãy kiểm tra tên miền trong Cài đặt."
                decisionHandler(.cancel); return
            }
        }
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode == 403 {
            deadline?.cancel(); loading = false
            error = "Aether yêu cầu xác minh hoặc từ chối truy cập. Bạn có thể kiểm tra hướng dẫn trong trang hoặc thử tên miền khác."
            decisionHandler(.allow); return
        }
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
            deadline?.cancel(); loading = false
            error = "Aether trả lỗi HTTP \(http.statusCode). Hãy thử lại hoặc chọn tên miền khác."
            decisionHandler(.cancel); return
        }
        if response.isForMainFrame { error = nil }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let url = action.request.url, let pinnedOrigin,
           AetherDomainPolicy.permitsNavigation(url, pinnedOrigin: pinnedOrigin), !pip.pending, !pip.active { webView.load(action.request) }
        return nil // No popups, external navigation, or a second audio/video owner.
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard pinnedOrigin != nil else { return }; startNavigationDeadline()
        // A new document owns new JS sessions. SPA route changes keep their existing video.
        pip = WebPiPSessionState(); pipDeadline?.cancel(); retainedForPiP = nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url, let pinnedOrigin,
              AetherDomainPolicy.permitsNavigation(url, pinnedOrigin: pinnedOrigin) else { return }
        deadline?.cancel(); loading = false; canGoBack = webView.canGoBack
        setAutomaticPiP(automatic)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    private func navigationFailed(_ error: Error) {
        guard pinnedOrigin != nil else { return }
        guard (error as? URLError)?.code != .cancelled else { return }
        deadline?.cancel(); loading = false; self.error = "Không tải được Aether. Kiểm tra kết nối hoặc mở lại phiên."
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        shutdown(); error = "Trình phát Aether đã dừng. Hãy mở lại phiên để tiếp tục."
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === webView, pinnedOrigin != nil else { return }
        if message.name == "mediaState", let state = message.body as? [String: Any] {
            let old = pip
            pip.snapshot(state)
            if let value = state["time"] as? Double, value.isFinite { time = max(0, value) }
            playing = state["playing"] as? Bool == true
            if old.active != pip.active { trace(pip.active ? "didStart" : "didStop", trigger: "website") }
        } else if message.name == "pipState", let state = message.body as? [String: String] {
            pip.event(state); trace(state["status"] ?? "unknown", trigger: "website")
        }
        finishPiPUpdate()
    }
    private func finishPiPUpdate() {
        if pip.active || pip.pending { retainedForPiP = self }
        else {
            pipDeadline?.cancel(); pipDeadline = nil
            retainedForPiP = nil
        }
    }
    private func trace(_ event: String, trigger: String) {
        PiPDiagnostics.record(event, backend: "webkit", sessionID: pip.sessionID ?? diagnosticID,
            trigger: trigger, view: webView, time: time,
            facts: ["supported": pip.supported, "pending": pip.pending, "active": pip.active])
    }

    static let observerJavaScript = """
    (function(){
      if(window.__anpinimeAetherObserver)return;window.__anpinimeAetherObserver=true;
      var activeVideo=null,automaticPiP=false;
      function send(name,value){try{window.webkit.messageHandlers[name].postMessage(value);}catch(e){}}
      function isAdvertisement(v){return !!v.closest('.advertisement,.video-ad,[data-ad="true"]');}
      \(WebPictureInPictureScript.core)
      function state(){
        var v=activeVideo;if(!v)return;var c=pipContext(v);syncPiP(v,c);
        send('mediaState',{pipSessionID:c.sessionID,pipRequestID:c.requestID,pipSupported:supportsPiP(v),pipActive:pipActive(v),pipPending:pipPending(v),pipError:c.error,time:v.currentTime||0,playing:!v.paused&&v.readyState>=2});
      }
      var observed=new WeakSet();
      function observe(){
        if(!window.document)return;
        var videos=Array.from(document.querySelectorAll('video')).filter(function(v){return !isAdvertisement(v);});
        videos.forEach(function(v){if(observed.has(v))return;observed.add(v);
          ['playing','pause','loadedmetadata','timeupdate','enterpictureinpicture','leavepictureinpicture','webkitpresentationmodechanged'].forEach(function(name){
            v.addEventListener(name,function(){if(pipActive(v)||!activeVideo||(!pipActive(activeVideo)&&!pipPending(activeVideo)&&!v.paused))activeVideo=v;state();});
          });
        });
        if(!activeVideo||(!pipActive(activeVideo)&&!pipPending(activeVideo))){
          activeVideo=videos.find(function(v){return !v.paused&&v.readyState>=2;})||videos[0]||null;
        }
        state();
      }
      window.addEventListener('message',function(event){
        var c=event.data;if(!c||c.type!=='AnPinimeCommand')return;
        if(c.name==='automaticPiP')automaticPiP=c.value===1;
        if(c.name==='pip'&&activeVideo)requestPiP(activeVideo,c);
        if(c.name==='pipStop'&&activeVideo)stopPiP(activeVideo);
        if(c.name==='endSession')document.querySelectorAll('video').forEach(function(v){stopPiP(v);v.pause();});
        if(c.name==='pause')document.querySelectorAll('video').forEach(function(v){if(!pipActive(v)&&!pipPending(v))v.pause();});
        document.querySelectorAll('iframe').forEach(function(f){try{f.contentWindow.postMessage(c,'*');}catch(e){}});
      });
      // No DOM/CSS changes, track/style changes, network interception, autoplay,
      // native handoff, or background-triggered PiP. The site owns its decoder.
      new MutationObserver(observe).observe(document.documentElement,{childList:true,subtree:true});
      setInterval(observe,1000);observe();
    })();
    """
}

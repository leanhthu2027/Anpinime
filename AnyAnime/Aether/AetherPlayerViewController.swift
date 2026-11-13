import UIKit
import AVFoundation

/// Aether supplies media URLs and captions. Only libmpv owns video decoding;
/// CinemaPlayerView and PlayerSettingsPanel remain the app's controls.
@MainActor
final class AetherPlayerViewController: UIViewController {
    private let episode: Episode
    private let playback: PlaybackState
    private let subtitles = AetherSubtitleClient()
    private var player: MPVPlaybackController?
    private var mediaRelay: FilmMediaRelay?
    private var stream: AetherStream?
    private var variant: AetherMediaVariant?
    private var captions: [AetherSubtitle] = []
    private var localCaptions: [String: URL] = [:]
    private var selectedCaption: AetherSubtitle?
    private var selectedFile: URL?
    private var secondaryFile: URL?
    private var attachedCaptions: [String: URL] = [:]
    private var primaryCaptionChosen = false
    private var pendingPrimaryCaption: String?
    private var subtitleOperation = UUID()
    private var requestTask: Task<Void, Never>?
    private var subtitleTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var domainTask: Task<URL?, Never>?
    private var qualityTask: Task<Void, Never>?
    private var generation = UUID()
    private var failedServers = Set<String>()
    private var failedVariants = Set<URL>()
    private var failedServerOptions = Set<String>()
    private var recovering = false
    private var decoderFailed = false
    private var live = true
    private var shutdownRequested = false
    private var retainedForPiP: AetherPlayerViewController?

    init(episode: Episode, service: AnimeService, playback: PlaybackState) {
        self.episode = episode; self.playback = playback
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        playback.engine = "mpv"
        if case .aether(let type, _, _, _) = episode.playback {
            playback.servers = AetherStreamClient.primaryServers.filter { AetherStreamClient.supports($0.id, mediaType:type) }.map { .init(id:$0.id,title:$0.name) }
        }
        playback.command = { [weak self] name, value in self?.player?.perform(name, value: value) }
        playback.chooseOption = { [weak self] kind, id in self?.choose(kind, id: id) }
        playback.importSubtitle = { [weak self] url, slot in
            guard let self, self.live else { return }
            self.cancelSubtitleWork()
            if slot == "subtitles" {
                self.primaryCaptionChosen = true; self.playback.externalSubtitle = nil
                self.selectedFile = url; self.selectedCaption = nil; self.playback.canTranslateSubtitle = false
            } else { self.secondaryFile = url; self.playback.externalSecondarySubtitle = nil }
            self.playback.subtitleStatus = url.lastPathComponent
            self.attachCaption(url, slot: slot, explicit: true)
        }
        playback.translateSubtitle = { [weak self] in self?.translate() }
        for name in ["AnPinime.sourceWillChange", "AnPinime.libraryWillChange", "AnPinime.playerWillStart"] {
            NotificationCenter.default.addObserver(self, selector: #selector(endExplicitly), name: Notification.Name(name), object: nil)
        }
        // Resolve the page origin once; native extraction must send the same
        // Origin/Referer context as Aether's browser requests.
        domainTask = Task { try? await AetherDomainResolver.shared.resolve().origin }
        load(serverID: nil)
    }

    func shutdown(force: Bool = false) {
        guard live else { return }
        if NativePiPPolicy.shouldDeferTeardown(active: playback.pictureInPictureActive,
            pending: playback.pictureInPicturePending, explicitEnd: force) {
            shutdownRequested = true; retainedForPiP = self
            requestTask?.cancel()
            return
        }
        live = false; generation = UUID()
        requestTask?.cancel(); subtitleTask?.cancel(); discoveryTask?.cancel(); restoreTask?.cancel(); domainTask?.cancel(); qualityTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        removePlayer()
        retainedForPiP = nil
    }
    @objc private func endExplicitly() { shutdown(force: true) }

    private func removePlayer() {
        mediaRelay?.stop(); mediaRelay = nil
        guard let old = player else { return }
        old.onPictureInPictureEnded = nil; old.onFailure = nil
        old.perform("pause", value: 0)
        old.shutdown(); old.willMove(toParent: nil); old.view.removeFromSuperview(); old.removeFromParent()
        player = nil
    }

    private func finishPiPBeforeReplacement() async throws {
        if playback.pictureInPictureActive || playback.pictureInPicturePending {
            player?.perform("pipStop", value: 0)
            for _ in 0..<40 {
                try Task.checkCancellation()
                if !playback.pictureInPictureActive && !playback.pictureInPicturePending { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw AetherNativeError.pictureInPictureBusy
        }
    }

    private func load(serverID: String?, serverOption: String? = nil) {
        guard live, !shutdownRequested else { return }
        requestTask?.cancel()
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await self.finishPiPBeforeReplacement()
                guard self.live, case .aether(let type, let id, let season, let number) = self.episode.playback else { return }
                self.playback.loading = true; self.playback.error = nil
                self.playback.serverLoading = true
                self.playback.serverMessage = serverID.flatMap { id in AetherStreamClient.servers.first { $0.id == id }?.name }.map { "Đang tìm " + $0 + "…" } ?? "Đang tìm nguồn phát…"
                let origin = await self.domainTask?.value ?? URL(string: "https://aether.cx/")!
                try Task.checkCancellation()
                let streams = AetherStreamClient(pageOrigin: origin)
                let result = try await streams.resolve(mediaType: type, id: id, season: season, episode: number, serverID: serverID, excluding: self.failedServers, serverOption: serverOption, excludingOptions: self.failedServerOptions,
                    progress: { [weak self] name in
                        guard let self, self.live, !Task.isCancelled else { return }
                        self.playback.serverMessage = "Đang thử nguồn: " + name + "…"
                    })
                try Task.checkCancellation()
                guard self.live, !self.shutdownRequested, let first = result.variants.first else { throw AetherNativeError.noMedia }
                // PiP may have started while extraction was waiting on the network.
                try await self.finishPiPBeforeReplacement()
                try Task.checkCancellation()
                guard self.live, !self.shutdownRequested else { return }
                self.cancelSubtitleWork(); self.discoveryTask?.cancel()
                self.generation = UUID(); self.stream = result; self.recovering = false; self.failedVariants = []
                self.playback.server = result.serverID
                self.playback.serverOptions = result.serverOptions.map { .init(id:$0.id,title:$0.name) }
                self.playback.serverOption = result.serverOption ?? ""
                self.playback.serverLoading = false; self.playback.serverMessage = nil
                if let actual = result.actualServerOption, let requested = result.serverOption, actual != requested {
                    self.playback.serverMessage = "Fast trả về " + actual + " cho lựa chọn " + requested + "."
                }
                self.playback.externalSubtitle = nil; self.playback.externalSubtitles = []
                self.playback.externalSecondarySubtitle = nil
                self.playback.subtitleStatus = nil; self.playback.subtitleBusy = false
                self.playback.canTranslateSubtitle = false; self.selectedCaption = nil; self.selectedFile = nil; self.secondaryFile = nil
                self.localCaptions = [:]; self.primaryCaptionChosen = false
                self.captions = result.captions.map { AetherSubtitle(id: "aether:" + $0.id, title: $0.title, language: $0.language, url: $0.url, headers: $0.headers) }
                self.publishCaptions()
                try await self.start(first, time: self.playback.currentTime, quality: "auto")
                if let preferred = AetherSubtitleClient.preferred(self.captions).first {
                    self.selectCaption(preferred, slot: "subtitles", automatic: true)
                }
                self.discoverSubtitles(type: type, id: id, season: season, number: number)
            } catch {
                guard self.live, !Task.isCancelled else { return }
                let wasRecovering = self.recovering
                if wasRecovering && serverID == "vidfast" {
                    self.failedServers.insert("vidfast")
                    self.load(serverID: nil)
                    return
                }
                self.recovering = false
                self.playback.loading = false; self.playback.serverLoading = false
                let label = serverID.flatMap { id in AetherStreamClient.servers.first { $0.id == id }?.name } ?? "Các nguồn"
                self.playback.serverMessage = label + ": " + error.localizedDescription
                if self.player == nil || wasRecovering || self.decoderFailed { self.playback.error = self.playback.serverMessage }
            }
        }
    }

    private func start(_ source: AetherMediaVariant, time: Double, quality: String) async throws {
        restoreTask?.cancel(); qualityTask?.cancel()
        removePlayer() // Pauses/detaches the previous decoder before starting another.
        attachedCaptions = [:]
        variant = source; decoderFailed = false
        playback.loading = true; playback.error = nil; playback.quality = quality
        playback.audioTracks = []; playback.subtitleTracks = [.init(id: "off", title: "Tắt phụ đề")]
        playback.subtitleTrack = "off"; playback.secondarySubtitleTrack = "off"
        if let stream {
            playback.qualities = [.automatic] + stream.variants.filter { $0.id != "auto" && !$0.id.hasPrefix("transport-") }.map {
                PlaybackQuality(id: $0.id, title: $0.label, bandwidth: 0, width: 0, height: 0)
            }
        }
        var playbackURL = source.url
        if source.requiresRelay {
            let relay = FilmMediaRelay(origin: source.url, headers: source.headers, preserveMediaExtensions: true,
                                       useSharedCookies: false, transportStreamEnvelope: true)
            mediaRelay = relay
            relay.onQualities = { [weak self, weak relay] qualities in
                guard let self, let relay, self.live, self.mediaRelay === relay else { return }
                self.playback.qualities = qualities
            }
            do { playbackURL = try await relay.start(source.url); try Task.checkCancellation() }
            catch { relay.stop(); if mediaRelay === relay { mediaRelay = nil }; throw error }
            guard live, !shutdownRequested else { relay.stop(); throw CancellationError() }
        }
        let controller = MPVPlaybackController(url: playbackURL, headers: source.requiresRelay ? [:] : source.headers, playback: playback)
        player = controller
        controller.onFailure = { [weak self, weak controller] message in
            guard let self, self.live, self.player === controller else { return }
            self.decoderFailed = true
            guard !self.recovering, !self.playback.serverLoading else { return }
            self.failedVariants.insert(source.url)
            if let stream = self.stream, let next = (stream.variants + stream.fallbackVariants).first(where: { !self.failedVariants.contains($0.url) }) {
                self.recovering = true
                self.requestTask?.cancel()
                self.requestTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.finishPiPBeforeReplacement()
                        try Task.checkCancellation()
                        guard self.live, !self.shutdownRequested else { return }
                        self.recovering = false
                        try await self.start(next, time: self.playback.currentTime, quality: "auto")
                    } catch {
                        guard !Task.isCancelled else { return }
                        self.recovering = false; self.playback.error = error.localizedDescription
                    }
                }
                return
            }
            if let stream = self.stream, stream.serverID == "vidfast", let option = stream.serverOption {
                self.failedServerOptions.insert(option)
                if stream.serverOptions.contains(where: { !self.failedServerOptions.contains($0.id) }) {
                    self.recovering = true
                    self.load(serverID: "vidfast")
                    return
                }
            }
            self.failedServers.insert(self.playback.server)
            if AetherStreamClient.primaryServers.contains(where: { !self.failedServers.contains($0.id) }) {
                self.recovering = true
                self.load(serverID: nil)
            } else {
                self.playback.loading = false; self.playback.error = message + " Các máy chủ dự phòng cũng chưa phát được phim này."
            }
        }
        controller.onPictureInPictureEnded = { [weak self, weak controller] in
            guard let self, self.player === controller else { return }
            if self.shutdownRequested { self.shutdown(force: true) }
        }
        addChild(controller); controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controller.view); controller.didMove(toParent: self)
        restoreSelection(on: controller, time: time)
        if stream?.variants.count == 1, (source.url.pathExtension.lowercased() == "m3u8" || source.url.path.hasSuffix("/m3u8-proxy")) { loadHLSQualities(source, controller: controller) }
    }

    private func restoreSelection(on controller: MPVPlaybackController, time: Double?) {
        restoreTask?.cancel()
        restoreTask = Task { [weak self, weak controller] in
            guard let self, let controller else { return }
            for _ in 0..<200 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled, self.live, self.player === controller else { return }
                if !self.playback.loading {
                    if let file = self.selectedFile { self.attachCaption(file, slot: "subtitles") }
                    if let file = self.secondaryFile { self.attachCaption(file, slot: "secondarySubtitles") }
                    if let time, time > 0 {
                        guard self.playback.duration > 0 else { continue }
                        controller.perform("seek", value: time)
                    }
                    return
                }
                if self.playback.error != nil { return }
            }
        }
    }

    private func loadHLSQualities(_ source: AetherMediaVariant, controller: MPVPlaybackController) {
        let token = generation
        qualityTask = Task { [weak self, weak controller] in
            do {
                var request = URLRequest(url: source.url)
                request.timeoutInterval = 15
                source.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let self, let controller, self.live, !Task.isCancelled,
                      self.generation == token, self.player === controller,
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      data.count <= 2 * 1024 * 1024,
                      let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else { return }
                self.playback.qualities = FilmMediaTransform.qualities(text)
            } catch { /* A playable HLS stream can remain on its default level. */ }
        }
    }

    private func choose(_ kind: String, id: String) {
        guard live, !shutdownRequested else { return }
        if kind == "serverOption" {
            guard stream?.serverID == "vidfast", stream?.serverOptions.contains(where: { $0.id == id }) == true else { return }
            recovering = false; failedServerOptions.remove(id)
            load(serverID: "vidfast", serverOption: id); return
        }
        if kind == "server" {
            guard id != playback.server || decoderFailed || playback.error != nil, AetherStreamClient.servers.contains(where: { $0.id == id }) else { return }
            recovering = false; failedServers.remove(id)
            if id == "vidfast" { failedServerOptions = [] }
            load(serverID: id); return
        }
        if kind == "quality", let stream {
            if stream.variants.count == 1, stream.variants[0].id == "auto" {
                guard id != playback.quality, playback.qualities.contains(where: { $0.id == id }) else { return }
                requestTask?.cancel()
                requestTask = Task { [weak self] in
                    guard let self, let current = self.player else { return }
                    do {
                        try await self.finishPiPBeforeReplacement(); try Task.checkCancellation()
                        guard self.live, !self.shutdownRequested, self.player === current else { return }
                        self.attachedCaptions = [:]
                        current.choose("quality", id: id)
                        self.restoreSelection(on: current, time: nil)
                    } catch {
                        if self.live, !Task.isCancelled { self.playback.pictureInPictureError = error.localizedDescription }
                    }
                }
                return
            }
            let choice = id == "auto" ? stream.variants.first : stream.variants.first { $0.id == id }
            guard let choice else { player?.choose(kind, id: id); return }
            guard id != playback.quality else { return }
            requestTask?.cancel()
            requestTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.finishPiPBeforeReplacement(); try Task.checkCancellation()
                    guard self.live, !self.shutdownRequested else { return }
                    try await self.start(choice, time: self.playback.currentTime, quality: id)
                } catch {
                    if self.live, !Task.isCancelled { self.playback.pictureInPictureError = error.localizedDescription }
                }
            }
            return
        }
        if kind == "subtitles" || kind == "secondarySubtitles" {
            if let caption = captions.first(where: { $0.id == id }) {
                selectCaption(caption, slot: kind); return
            }
            if let file = localCaptions[id] {
                cancelSubtitleWork()
                if kind == "subtitles" {
                    primaryCaptionChosen = true; playback.externalSubtitle = id; selectedFile = file
                    selectedCaption = nil; playback.canTranslateSubtitle = false
                } else { secondaryFile = file; playback.externalSecondarySubtitle = id }
                attachCaption(file, slot: kind, explicit: true); return
            }
            cancelSubtitleWork()
            if kind == "subtitles" {
                primaryCaptionChosen = true; playback.externalSubtitle = nil
                playback.canTranslateSubtitle = false; selectedCaption = nil; selectedFile = nil
            } else { secondaryFile = nil; playback.externalSecondarySubtitle = nil }
            attachedCaptions[kind] = nil
            playback.subtitleStatus = nil
        }
        player?.choose(kind, id: id)
    }

    private func publishCaptions() {
        playback.externalSubtitles = captions.map { .init(id: $0.id, title: $0.title) }
        for translated in localCaptions.keys.filter({ $0.hasPrefix("translated:") }).sorted() {
            playback.externalSubtitles.append(.init(id: translated, title: "Tiếng Việt · bản dịch Aether"))
        }
    }

    private func discoverSubtitles(type: String, id: Int, season: Int?, number: Int?) {
        let token = generation
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            let imdbID = try? await AetherProvider().imdbID(mediaType: type, id: id)
            guard self.live, !Task.isCancelled, self.generation == token else { return }
            let extra = await self.subtitles.external(mediaType: type, id: id, season: season, episode: number, imdbID: imdbID)
            guard self.live, !Task.isCancelled, self.generation == token else { return }
            var known = Set(self.captions.map { $0.url })
            self.captions += extra.filter { known.insert($0.url).inserted }
            self.publishCaptions()
            if !self.primaryCaptionChosen, let preferred = AetherSubtitleClient.preferred(self.captions).first {
                let upgrade = Self.isVietnamese(preferred.language) && self.selectedCaption?.language != "vi"
                let unselected = self.playback.externalSubtitle == nil && self.playback.subtitleTrack == "off" && self.pendingPrimaryCaption == nil
                if (upgrade || unselected), self.playback.externalSubtitle != preferred.id, self.pendingPrimaryCaption != preferred.id {
                    self.selectCaption(preferred, slot: "subtitles", automatic: true)
                }
            } else if self.captions.isEmpty {
                self.playback.subtitleStatus = "Máy chủ chưa cung cấp phụ đề rời. Có thể chọn track trong video hoặc nhập file."
            }
        }
    }

    private func selectCaption(_ caption: AetherSubtitle, slot: String, automatic: Bool = false) {
        cancelSubtitleWork()
        if slot == "subtitles", !automatic { primaryCaptionChosen = true }
        if slot == "subtitles" { pendingPrimaryCaption = caption.id }
        let token = generation, operation = subtitleOperation
        subtitleTask = Task { [weak self] in
            guard let self, self.ownsSubtitleOperation(token, operation), !Task.isCancelled else { return }
            self.playback.subtitleBusy = true; self.playback.subtitleStatus = "Đang tải phụ đề…"
            defer { if self.ownsSubtitleOperation(token, operation) { self.playback.subtitleBusy = false } }
            do {
                let file: URL
                if let cached = self.localCaptions[caption.id] { file = cached }
                else { file = try await self.subtitles.materialize(caption) }
                try Task.checkCancellation()
                guard self.ownsSubtitleOperation(token, operation) else { return }
                self.localCaptions[caption.id] = file
                if slot == "subtitles" {
                    self.playback.externalSubtitle = caption.id; self.selectedCaption = caption; self.selectedFile = file
                    self.playback.canTranslateSubtitle = !Self.isVietnamese(caption.language)
                    self.pendingPrimaryCaption = nil
                } else { self.secondaryFile = file; self.playback.externalSecondarySubtitle = caption.id }
                self.attachCaption(file, slot: slot, explicit: true)
                self.playback.subtitleStatus = caption.title
                if automatic, slot == "subtitles", !Self.isVietnamese(caption.language) {
                    self.translate()
                }
            } catch {
                guard self.ownsSubtitleOperation(token, operation), !Task.isCancelled else { return }
                if slot == "subtitles" { self.pendingPrimaryCaption = nil }
                self.playback.subtitleStatus = error.localizedDescription
            }
        }
    }

    private func translate() {
        guard live, let file = selectedFile, let caption = selectedCaption,
              !Self.isVietnamese(caption.language) else { return }
        cancelSubtitleWork()
        let token = generation, operation = subtitleOperation
        subtitleTask = Task { [weak self] in
            guard let self, self.ownsSubtitleOperation(token, operation), !Task.isCancelled else { return }
            self.playback.subtitleBusy = true; self.playback.subtitleStatus = "Đang dịch phụ đề sang tiếng Việt…"
            defer { if self.ownsSubtitleOperation(token, operation) { self.playback.subtitleBusy = false } }
            do {
                let translated = try await self.subtitles.translateToVietnamese(file) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.ownsSubtitleOperation(token, operation), self.playback.subtitleBusy else { return }
                        self.playback.subtitleStatus = "Đang dịch sang tiếng Việt · \(Int(progress * 100))%"
                    }
                }
                try Task.checkCancellation()
                guard self.ownsSubtitleOperation(token, operation) else { return }
                let id = "translated:" + caption.id
                self.localCaptions[id] = translated; self.selectedFile = translated; self.selectedCaption = nil
                self.playback.externalSubtitle = id; self.playback.canTranslateSubtitle = false
                self.publishCaptions(); self.attachCaption(translated, slot: "subtitles", explicit: true)
                self.playback.subtitleStatus = "Tiếng Việt · bản dịch Aether"
            } catch {
                guard self.ownsSubtitleOperation(token, operation), !Task.isCancelled else { return }
                self.playback.subtitleStatus = "Chưa dịch được phụ đề: " + error.localizedDescription
            }
        }
    }

    private func cancelSubtitleWork() {
        subtitleTask?.cancel(); subtitleTask = nil
        subtitleOperation = UUID(); playback.subtitleBusy = false; pendingPrimaryCaption = nil
    }
    private func ownsSubtitleOperation(_ token: UUID, _ operation: UUID) -> Bool {
        live && generation == token && subtitleOperation == operation
    }
    private func attachCaption(_ file: URL, slot: String, explicit: Bool = false) {
        guard let player, explicit || attachedCaptions[slot] != file else { return }
        // mpv permits each track in only one subtitle lane. Move a file rather
        // than retaining conflicting selections that would reappear on reload.
        if slot == "subtitles", secondaryFile == file {
            secondaryFile = nil; playback.externalSecondarySubtitle = nil
            attachedCaptions["secondarySubtitles"] = nil
            player.choose("secondarySubtitles", id: "off")
        } else if slot == "secondarySubtitles", selectedFile == file {
            selectedFile = nil; selectedCaption = nil; primaryCaptionChosen = true
            playback.externalSubtitle = nil; playback.canTranslateSubtitle = false
            attachedCaptions["subtitles"] = nil
            player.choose("subtitles", id: "off")
        }
        attachedCaptions[slot] = file
        player.addSubtitle(file, slot: slot)
    }
    private static func isVietnamese(_ language: String) -> Bool {
        ["vi", "vie", "vietnamese", "tiếng việt"].contains(language.lowercased())
    }
}

private enum AetherNativeError: LocalizedError {
    case pictureInPictureBusy, noMedia
    var errorDescription: String? {
        self == .pictureInPictureBusy ? "Chờ PiP đóng trước khi đổi máy chủ hoặc chất lượng." : "Máy chủ chưa trả luồng video phát trực tiếp."
    }
}

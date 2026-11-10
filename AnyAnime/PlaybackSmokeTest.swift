#if DEBUG
import SwiftUI

enum PlaybackSmokeTest {
    static var enabled: Bool {
        animeSmoke || mpvFixture || ProcessInfo.processInfo.arguments.contains("--playback-smoke") || webOnly || movieSource != nil
    }
    static var mpvFixture: Bool { ProcessInfo.processInfo.arguments.contains("--mpv-playback-smoke") && !source2Diagnostic && !animeSmoke }
    static var animeFixture: Bool { ProcessInfo.processInfo.arguments.contains("--anime-provider-smoke") }
    static var liveAnime: Bool { ProcessInfo.processInfo.arguments.contains("--anime-live-smoke") }
    static var animeNativeFailure: Bool { ProcessInfo.processInfo.arguments.contains("--anime-native-failure-smoke") }
    static var animeSmoke: Bool { animeFixture || liveAnime || animeNativeFailure }
    static var source2HLS: Bool { ProcessInfo.processInfo.arguments.contains("--relay-hls-smoke") }
    static var source2Diagnostic: Bool { source2HLS }
    static var webOnly: Bool { ProcessInfo.processInfo.arguments.contains("--web-playback-smoke") }
    static var providerFixture: Bool { source2HLS || ProcessInfo.processInfo.arguments.contains("--movie-provider-smoke") }
    static var movieSource: ContentSource? {
        if source2HLS { return .kkphim } // Shared JSON/HLS fixture, no retired provider.
        if ProcessInfo.processInfo.arguments.contains("--movie-provider-smoke") || liveMovie { return .film4k }
        return nil
    }
    static var liveMovie: Bool { ProcessInfo.processInfo.arguments.contains("--film4k-live-smoke") }
    static var resultName: String? {
        if animeNativeFailure { return "anime-native-fallback" }
        if animeFixture { return "anime-provider" }
        if liveAnime { return "anime-live" }
        if liveMovie { return "film4k-live" }
        if source2HLS { return "relay-hls" }
        return movieSource?.rawValue
    }
    @MainActor static var animeEpisodeCount = 0
    @MainActor static var selectedAnimeEpisodeNumber: Int?
    @MainActor static var cancelledAnimeLoadVerified = false
    @MainActor private static var firstVideoTime: Double?
    @MainActor private static var events: [[String: Any]] = []
    @MainActor private static var diagnosticStartedAt: TimeInterval?
    @MainActor private static var firstDecodedVideoRecorded = false
    @MainActor private static var fileLoadedRecorded = false
    @MainActor private static var firstDecodedVideoElapsed: TimeInterval?
    @MainActor private static var fileLoadedElapsed: TimeInterval?
    @MainActor private static var recoveredWebStartTime: Double?
    @MainActor static func diagnostic(_ event: String, fields: [String: Any]) {
        guard source2Diagnostic || animeSmoke || mpvFixture else { return }
        var entry = fields
        // libmpv warnings may contain upstream or loopback URLs. Never retain
        // signed queries, cookies, tickets or the relay's per-playback IDs.
        for (key, value) in fields {
            if let value = value as? String {
                entry[key] = value.replacingOccurrences(of: #"https?://[^\s\"'<>]+"#, with: "[URL]", options: .regularExpression)
                    .replacingOccurrences(of: #"(?i)(cookie|authorization|api-key|token|x-f4k-pt)\s*[:=][^\r\n]*"#,
                                          with: "$1=[redacted]", options: .regularExpression)
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        if diagnosticStartedAt == nil { diagnosticStartedAt = now }
        entry["elapsedSeconds"] = now - diagnosticStartedAt!
        entry["event"] = event
        if source2Diagnostic, event == "mpv-state" {
            // Preserve startup milestones before later snapshots are coalesced.
            if !fileLoadedRecorded, fields["loaded"] as? Bool == true {
                fileLoadedRecorded = true
                fileLoadedElapsed = now - diagnosticStartedAt!
                var milestone = entry
                milestone["event"] = "source2-file-loaded"
                events.append(milestone)
            }
            if !firstDecodedVideoRecorded, fields["playing"] as? Bool == true,
               (fields["time"] as? Double ?? 0) > 0,
               (fields["videoWidth"] as? Double ?? 0) > 0,
               (fields["videoHeight"] as? Double ?? 0) > 0 {
                firstDecodedVideoRecorded = true
                firstDecodedVideoElapsed = now - diagnosticStartedAt!
                var milestone = entry
                milestone["event"] = "source2-first-decoded-video"
                events.append(milestone)
            }
        }
        if event == "mpv-state", events.last?["event"] as? String == event { events.removeLast() }
        events.append(entry)
        if events.count > 120 { events.removeFirst(events.count - 120) }
        write(["events": events], name: "\(resultName ?? "mpv")-diagnostics")
    }
    @MainActor private static func write(_ result: [String: Any], name: String) {
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
           let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: directory.appendingPathComponent("playback-\(name).json"), options: .atomic)
        }
    }
    @MainActor static func record(time: Double, backend: String, size: CGSize, playback: PlaybackState? = nil, videoSize: CGSize = .zero) {
        guard enabled, time > 1, size.width > size.height else { return }
        if animeSmoke {
            guard let playback, playback.playing, videoSize.width > 0, videoSize.height > 0,
                  selectedAnimeEpisodeNumber == 1, animeEpisodeCount >= (animeFixture ? 2 : 1) else { return }
        }
        var result: [String: Any] = ["time": time, "backend": backend, "landscape": true,
                                     "width": size.width, "height": size.height]
        if let playback {
            if mpvFixture {
                guard backend == "mpv", playback.playing, playback.audioTracks.count == 2, playback.subtitleTracks.count >= 3 else { return }
                let audio = playback.audioTracks.last!, subtitles = playback.subtitleTracks.filter { $0.id != "off" }
                playback.chooseOption?("audio", audio.id)
                playback.chooseOption?("subtitles", subtitles[0].id)
                playback.chooseOption?("secondarySubtitles", subtitles[1].id)
                guard playback.audioTrack == audio.id, playback.subtitleTrack == subtitles[0].id,
                      playback.secondarySubtitleTrack == subtitles[1].id else { return }
                guard playback.pipSmokeFrames >= 8, playback.pipSmokeSeekPauseRestored else { return }
                result["pipSoftwareVisibleFrames"] = playback.pipSmokeFrames
                result["pipSeekPauseRestoreVerified"] = playback.pipSmokeSeekPauseRestored
                result["pipSystemWindowOnDeviceVerified"] = false
                result["mkvAudioAndDualSubtitlesVerified"] = true
                result["autoplayVerified"] = true
            }
            if source2Diagnostic || animeSmoke {
                guard backend == "mpv" || (animeSmoke && backend == "web"), playback.playing, videoSize.width > 0, videoSize.height > 0 else { return }
                if animeNativeFailure {
                    guard backend == "web", events.contains(where: { $0["event"] as? String == "anime-native-failed" }),
                          events.contains(where: { $0["event"] as? String == "anime-web-restored" && $0["reusedWebsite"] as? Bool == true }),
                          !playback.loading, !playback.buffering, playback.error == nil else { return }
                    if recoveredWebStartTime == nil { recoveredWebStartTime = time }
                    guard time - recoveredWebStartTime! >= 1 else { return }
                    result["nativeFailureRecoveryVerified"] = true
                    result["sameWebsiteRestoredVerified"] = true
                    result["loadingClearedVerified"] = true
                }
                if firstVideoTime == nil { firstVideoTime = time }
                guard time - firstVideoTime! >= 1 else { return }
                result["sample"] = "Local shared HLS through relay"
                result["mediaInfo"] = playback.mediaInfo
                result["videoWidth"] = videoSize.width
                result["videoHeight"] = videoSize.height
                result["advancingVideoVerified"] = true
                if source2Diagnostic {
                    result["videoCodec"] = playback.mediaInfo.components(separatedBy: " · ").dropFirst().first ?? ""
                    if let elapsed = firstDecodedVideoElapsed { result["firstDecodedVideoElapsedSeconds"] = elapsed }
                    if let elapsed = fileLoadedElapsed { result["fileLoadedElapsedSeconds"] = elapsed }
                    result["startupTimingResolutionSeconds"] = 0.25
                }
                if animeSmoke {
                    result["sample"] = animeNativeFailure ? "Decoded WebKit blob → native HTTP 403 → same WebKit video resumes" : liveAnime ? "AnimeVietsub .news / Bleach a5985" : "Local anime metadata → dynamic episodes → player"
                    result["episodeCount"] = animeEpisodeCount
                    result["selectedEpisodeNumber"] = selectedAnimeEpisodeNumber ?? 0
                    if animeFixture {
                        guard cancelledAnimeLoadVerified else { return }
                        result["cancelledEpisodeLoadVerified"] = true
                    }
                }
            }
            result["audioChoices"] = playback.audioTracks.count
            result["subtitleChoices"] = playback.subtitleTracks.count
            result["qualityChoices"] = playback.qualities.count
            if providerFixture, movieSource == .film4k {
                guard playback.subtitleTracks.count >= 3, playback.qualities.count >= 2,
                      let last = playback.subtitleTracks.last, let quality = playback.qualities.last else { return }
                playback.chooseOption?("subtitles", last.id)
                guard playback.subtitleTrack == last.id else { return }
                playback.chooseOption?("subtitles", "stale-option-from-old-video")
                guard playback.subtitleTrack == last.id else { return }
                playback.chooseOption?("subtitles", "off")
                guard playback.subtitleTrack == "off" else { return }
                playback.chooseOption?("quality", quality.id)
                guard playback.quality == quality.id else { return }
                result["stableSelectionAndOffVerified"] = true
            }
        }
        write(result, name: resultName ?? backend)
    }
}

struct PlaybackSmokeView: View {
    private let episode = Episode(title: "Tập kiểm thử", url: URL(string: "http://127.0.0.1:8765/episode.html")!, number: 1, season: "Phần 1")
    var body: some View {
        if PlaybackSmokeTest.animeNativeFailure {
            PlayerView(episode: episode, title: "Khôi phục anime sau lỗi native", artworkURL: nil, episodes: [episode])
                .onAppear {
                    PlaybackSmokeTest.animeEpisodeCount = 1
                    PlaybackSmokeTest.selectedAnimeEpisodeNumber = 1
                }
        }
        else if PlaybackSmokeTest.animeSmoke { AnimeSmokeView() }
        else if PlaybackSmokeTest.mpvFixture {
            let media = URL(string: "http://127.0.0.1:8765/multitrack.mkv")!
            let item = Episode(title: "MKV · Hai âm thanh · Hai phụ đề", url: media, number: 1, season: "Kiểm thử", source: .kkphim,
                               playback: .directStream(url: media, webURL: nil, isWeb: false, referer: media))
            PlayerView(episode: item, title: "Kiểm thử mpv", artworkURL: nil, episodes: [item])
        } else if let source = PlaybackSmokeTest.movieSource { MovieSmokeView(source: source) }
        else { PlayerView(episode: episode, title: "Kiểm thử phát video", artworkURL: nil, episodes: [episode]) }
    }
}

private struct AnimeSmokeView: View {
    @EnvironmentObject private var service: AnimeService
    @State private var detail: AnimeDetail?
    @State private var error = ""
    var body: some View {
        ZStack {
            if let detail, let episode = detail.episodes.first(where: { $0.number == 1 }) {
                PlayerView(episode: episode, title: detail.title, artworkURL: detail.posterURL, episodes: detail.episodes)
            } else {
                Text(error.isEmpty ? "Kiểm thử Anime: thông tin → tập → video" : error)
                    .task {
                        do {
                            service.selectSource(.anime)
                            let item: Anime
                            if PlaybackSmokeTest.animeFixture {
                                await service.loadHome(forceDomainRefresh: true)
                                guard let first = service.homeSections.flatMap(\.items).first else { throw AnimeServiceError.emptyData }
                                item = first
                            } else {
                                item = Anime(title: "Bleach", url: URL(string: "https://animevietsub.news/phim/bleach-sennen-kessen-hen-kashin-tan-a5985/")!,
                                             imageURL: nil, episodeText: "", quality: "", score: "")
                            }
                            let meta = try await service.detailMetadata(for: item, forceRefresh: true)
                            if PlaybackSmokeTest.animeFixture {
                                let cancelledLoad = Task { try await service.loadEpisodes(for: item, initialDetail: meta, forceRefresh: true) }
                                try await Task.sleep(nanoseconds: 500_000_000)
                                cancelledLoad.cancel()
                                do {
                                    _ = try await cancelledLoad.value
                                    throw AnimeServiceError.emptyData
                                } catch is CancellationError { }
                                guard service.cachedDetail(for: item.id) == nil else { throw AnimeServiceError.emptyData }
                                PlaybackSmokeTest.cancelledAnimeLoadVerified = true
                                PlaybackSmokeTest.diagnostic("cancelled-episode-load", fields: ["partialCacheAbsent": true])
                            }
                            let episodes = try await service.loadEpisodes(for: item, initialDetail: meta, forceRefresh: true)
                            guard let selected = episodes.first(where: { $0.number == 1 }) else { throw AnimeServiceError.emptyData }
                            PlaybackSmokeTest.animeEpisodeCount = episodes.count
                            PlaybackSmokeTest.selectedAnimeEpisodeNumber = selected.number
                            PlaybackSmokeTest.diagnostic("anime-episodes", fields: ["episodeCount": episodes.count,
                                "selectedEpisodeNumber": selected.number ?? 0, "host": selected.url.host ?? "", "path": selected.url.path])
                            detail = AnimeDetail(title: meta.title, posterURL: meta.posterURL, bannerURL: meta.bannerURL,
                                                 summary: meta.summary, info: meta.info, episodes: episodes)
                        } catch {
                            self.error = error.localizedDescription
                            PlaybackSmokeTest.diagnostic("failure", fields: ["stage": "anime-episodes", "message": self.error])
                        }
                    }
            }
            VerificationGate(browser: service.website)
        }
    }
}

private struct MovieSmokeView: View {
    @EnvironmentObject private var service: AnimeService
    let source: ContentSource
    @State private var detail: AnimeDetail?
    @State private var error = ""
    private var selectedEpisode: Episode? { detail?.episodes.first }
    var body: some View {
        Group {
            if let detail, let episode = selectedEpisode {
                PlayerView(episode: episode, title: detail.title, artworkURL: detail.posterURL, episodes: detail.episodes)
            } else {
                Text(error.isEmpty ? "Kiểm thử danh sách → chi tiết → video" : error)
                    .task {
                        do {
                            service.selectSource(source)
                            await service.loadHome()
                            let items = service.homeSections.flatMap(\.items)
                            guard let item = items.first else { throw MovieSourceError.unavailable(service.status) }
                            detail = try await service.detail(for: item)
                            if selectedEpisode == nil { throw MovieSourceError.noVideo }
                        } catch {
                            self.error = error.localizedDescription
                            PlaybackSmokeTest.diagnostic("failure", fields: ["stage": "catalog-detail", "message": self.error])
                        }
                    }
            }
        }
    }

}
#endif

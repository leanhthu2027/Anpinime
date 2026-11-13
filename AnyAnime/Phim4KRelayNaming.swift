import Foundation

/// FFmpeg's HLS demuxer checks segment extensions before fetching them.
/// Keep opaque relay IDs, but retain known media suffixes for source 2.
enum Phim4KRelayNaming {
    static func suffix(for url: URL, transportStreamEnvelope: Bool = false) -> String {
        var url = url
        if transportStreamEnvelope {
            // Aether's public HLS proxy nests the real media URL in `url`.
            // This affects the local suffix only; requests retain the exact URL.
            for _ in 0..<3 {
                guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
                      let nested = URL(string: raw), ["http", "https"].contains(nested.scheme ?? "") else { break }
                url = nested
            }
            if url.path.contains("/seg/") || ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()) { return "ts" }
        }
        if url.path.contains("/stream/hls") { return "m3u8" }
        let ext = url.pathExtension.lowercased()
        let allowed = ["m3u8", "ts", "m4s", "mp4", "m4a", "aac", "mp3", "ac3", "ec3", "vtt", "webvtt"]
        return allowed.contains(ext) ? ext : "bin"
    }
}

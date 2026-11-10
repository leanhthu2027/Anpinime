import Foundation

/// No invented JSON endpoints or media routes. Catalog, search, details,
/// seasons and playback remain in the site's own UI until a contract is verified.
@MainActor
final class AetherProvider: MovieSourceProviding {
    let baseURL = AetherDomainPolicy.defaultURL
    let categories: [AnimeCategory] = []
    let notice = "Tìm kiếm, thể loại, tập phim và phụ đề được điều khiển trong Aether."
    func invalidate() { }
    func home(onInitial: ([AnimeSection]) -> Void) async throws -> [AnimeSection] { [] }
    func list(path: String, page: Int) async throws -> [Anime] { throw AetherError.browserRequired }
    func search(_ query: String) async throws -> [Anime] { throw AetherError.browserRequired }
    func detail(_ anime: Anime) async throws -> AnimeDetail { throw AetherError.browserRequired }
    func resolve(_ episode: Episode, refresh: Bool) async throws -> ResolvedPlayback {
        // Browser navigation owns playback. An arbitrary catalog item cannot
        // synthesize an Aether URL or force the native MPV handoff path.
        throw AetherError.browserRequired
    }
}

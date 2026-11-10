import Foundation

/// Native JSON providers and the website-owned Aether MVP share a router,
/// without teaching the public JSON client about Aether's unverified API.
@MainActor
protocol MovieSourceProviding: AnyObject {
    var baseURL: URL { get }
    var categories: [AnimeCategory] { get }
    var notice: String { get }
    func invalidate()
    func home(onInitial: ([AnimeSection]) -> Void) async throws -> [AnimeSection]
    func list(path: String, page: Int) async throws -> [Anime]
    func search(_ query: String) async throws -> [Anime]
    func detail(_ anime: Anime) async throws -> AnimeDetail
    func resolve(_ episode: Episode, refresh: Bool) async throws -> ResolvedPlayback
}

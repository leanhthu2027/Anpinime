import Foundation

enum MovieSourceMigration {
    static let selectionKey = "AnPinime.movieSource"
    /// Idempotent and deliberately limited to selection. Legacy searches/watch
    /// positions stay under phim4k keys; there is no verified movie ID mapping.
    @discardableResult
    static func migrate(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.string(forKey: selectionKey) == "phim4k" else { return false }
        defaults.set(ContentSource.aether.rawValue, forKey: selectionKey)
        return true
    }
}

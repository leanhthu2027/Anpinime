import Foundation

@main struct AetherIntegrationTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError("FAIL: " + message) }; checks += 1; print("PASS: " + message)
    }
    @MainActor static func main() async throws {
        let name = "AnPinime.MigrationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("phim4k", forKey: MovieSourceMigration.selectionKey)
        defaults.set("aiDrama", forKey: "AnPinime.selectedLibrary")
        defaults.set(["Old movie"], forKey: "AnPinime.searchHistory.phim4k")
        defaults.set(["Anime"], forKey: "AnPinime.searchHistory.anime")
        defaults.set(["Free"], forKey: "AnPinime.searchHistory.film4k")
        defaults.set(["Backup"], forKey: "AnPinime.searchHistory.kkphim")
        defaults.set(["episode-123": 71.5], forKey: "AnPinime.AIDrama.positions.series-1")
        let before = defaults.dictionaryRepresentation()
        check(MovieSourceMigration.migrate(defaults: defaults), "saved source-2 selection migrates to Aether")
        check(defaults.string(forKey: MovieSourceMigration.selectionKey) == "aether", "Aether occupies the source-2 slot")
        for (key, value) in before where key != MovieSourceMigration.selectionKey {
            check(NSDictionary(dictionary: [key: value]).isEqual(to: [key: defaults.object(forKey: key)!]), "migration preserves " + key)
        }
        check(!MovieSourceMigration.migrate(defaults: defaults), "migration is idempotent")
        let history = SearchHistory(defaults: defaults)
        check(history.queries(for: .aether).isEmpty, "old movie IDs/searches are not reinterpreted as Aether history")
        history.record("Aether query", source: .aether)
        check(defaults.stringArray(forKey: "AnPinime.searchHistory.phim4k") == ["Old movie"], "new history cannot overwrite the retained legacy namespace")
        for source in [ContentSource.film4k, .kkphim] {
            defaults.set(source.rawValue, forKey: MovieSourceMigration.selectionKey)
            check(!MovieSourceMigration.migrate(defaults: defaults) && defaults.string(forKey: MovieSourceMigration.selectionKey) == source.rawValue, "unchanged source selection " + source.rawValue)
        }
        check(ContentSource.allCases.map(\.rawValue) == ["anime", "film4k", "aether", "kkphim"], "production source enum exposes exactly the four intended sources")
        check(ContentSource.aether.title == "Anpinime VIP" && ContentSource.film4k.title == "Anpinime Free" && ContentSource.kkphim.title == "Anpinime dự phòng", "source labels are unambiguous")
        verifyPiPSessions()
        print("\(checks) Aether migration/bridge checks passed")
    }
    static func verifyPiPSessions() {
        var pip = WebPiPSessionState()
        func snapshot(_ session: String = "video-1", _ request: String = "", active: Bool = false) -> [String: Any] {
            ["pipSessionID": session, "pipRequestID": request, "pipSupported": true, "pipActive": active, "pipPending": false]
        }
        check(pip.begin(requestID: "early") == nil, "PiP cannot start before HTML video reports support")
        pip.snapshot(snapshot())
        check(pip.begin(requestID: "first") == "video-1" && pip.pending, "manual request records pending ownership before JavaScript")
        pip.snapshot(snapshot())
        check(pip.pending, "late inline snapshot cannot clear pending PiP")
        check(!pip.snapshot(snapshot("foreign-frame", "first")), "a rejected iframe snapshot cannot update the owner's playback fields")
        pip.event(["sessionID":"other-frame","requestID":"first","status":"error"])
        check(pip.pending, "another iframe cannot reject the selected video")
        pip.event(["sessionID":"video-1","requestID":"first","status":"active"])
        check(pip.active && !pip.pending, "only the matching presentation event establishes active state")
        pip.snapshot(snapshot("video-1", "first"))
        check(pip.active, "inline media snapshots do not close active PiP")
        pip.fail(requestID: "first", sessionID: "video-1", reason: "timeout")
        check(pip.active && pip.error.isEmpty, "a delayed timeout cannot reject an active system presentation")
        pip.event(["sessionID":"video-1","requestID":"first","status":"stopped"])
        check(!pip.active, "matching stop releases PiP ownership")
        _ = pip.begin(requestID: "retry")
        pip.fail(requestID: "first", sessionID: "video-1", reason: "timeout")
        check(pip.pending, "an old request timeout cannot cancel a retry")
        pip.fail(requestID: "retry", sessionID: "video-1", reason: "rejected")
        check(!pip.pending && pip.error == "rejected", "Promise rejection/timeout enables a later retry")
        pip.snapshot(snapshot("video-2", "", active: true))
        check(pip.active && pip.requestID == "", "website-controlled PiP is adopted without a native request")
        pip.event(["sessionID":"video-2","requestID":"","status":"stopped"])
        check(!pip.active && !pip.pending, "website-controlled stop releases the adopted session")
    }
}

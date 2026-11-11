import Foundation

@main struct MetadataCredentialTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fatalError(label) }
        count += 1
    }
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("MetadataCredentials.plist")
        let fixture = String(repeating: "a", count: 32)
        func save(_ dictionary: [String: String]) throws {
            try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0).write(to: url)
        }
        try save(["TMDB_API_KEY": fixture])
        check(AetherMetadataSettings.configuredCredential(environment: [:], stored: nil, bundleURL: url) == fixture,
              "a packaged default configures metadata without user input")
        check(AetherMetadataSettings.configuredCredential(environment: [:], stored: "stored-token", bundleURL: url) == "stored-token",
              "an explicit Keychain choice overrides the packaged default")
        check(AetherMetadataSettings.configuredCredential(environment: ["TMDB_READ_TOKEN": "runtime-token"], stored: "stored-token", bundleURL: url) == "runtime-token",
              "runtime binding retains priority")
        check(AetherMetadataSettings.configuredCredential(environment: ["TMDB_API_KEY": "invalid"], stored: nil, bundleURL: url) == fixture,
              "malformed runtime API key cannot disable a valid packaged default")
        try save(["TMDB_READ_TOKEN": "packaged-read-token"])
        check(AetherMetadataSettings.configuredCredential(environment: [:], stored: nil, bundleURL: url) == "packaged-read-token",
              "packaged read tokens are supported as well as API keys")
        try save(["TMDB_API_KEY": "short"])
        check(AetherMetadataSettings.configuredCredential(environment: [:], stored: nil, bundleURL: url) == nil,
              "truncated packaged API key is rejected")
        try save(["TMDB_READ_TOKEN": "contains\nwhitespace"])
        check(AetherMetadataSettings.configuredCredential(environment: [:], stored: nil, bundleURL: url) == nil,
              "invalid packaged header value is rejected")
        try Data("invalid plist".utf8).write(to: url)
        check(AetherMetadataSettings.configuredCredential(environment: [:], stored: nil, bundleURL: url) == nil,
              "corrupt resource is handled without exposing its contents")
        check(AetherMetadataSettings.configuredCredential(environment: [:], stored: nil, bundleURL: nil) == nil,
              "missing packaged configuration remains a diagnosable failure")
        print("\(count) private metadata default checks passed")
    }
}

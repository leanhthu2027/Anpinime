import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main struct AetherTransportTests {
    static func main() async throws {
        guard let port = ProcessInfo.processInfo.environment["ANPINIME_RANGE_PORT"] else { fatalError("missing fixture port") }
        let client = AetherStreamClient()
        for path in ["range", "ignore", "redirect"] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(path)")!, timeoutInterval: 5)
            request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
            let (data, response) = try await client.transport(request)
            guard data.count == 65_536, [200,206].contains(response.statusCode), AetherStreamClient.isMediaPrefix(data) else {
                fatalError("media prefix not bounded: \(path)")
            }
        }
        let oversized = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/ignore")!, timeoutInterval: 5)
        do { _ = try await client.transport(oversized); fatalError("unbounded JSON download accepted") }
        catch AetherStreamError.invalidResponse { }
        let json = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/json")!, timeoutInterval: 5)
        let (body, response) = try await client.transport(json)
        guard response.statusCode == 200, String(decoding:body,as:UTF8.self) == #"{"error":"not media"}"# else { fatalError("JSON response changed") }
        let operation = Task { try await client.transport(oversized) }
        operation.cancel()
        do { _ = try await operation.value; fatalError("cancelled request completed") }
        catch is CancellationError { }
        print("PASS: 6 bounded native Aether transport checks, including a server ignoring Range on a virtual 12 GB file")
    }
}

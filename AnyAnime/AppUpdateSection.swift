import SwiftUI

/// Queries successful packages, not unreleased commits on the development branch.
struct AppUpdateSection: View {
    @State private var checking = false
    @State private var message = ""
    @State private var updateURL: URL?
    var body: some View {
        Section("Cập nhật ứng dụng") {
            Button(checking ? "Đang kiểm tra…" : "Kiểm tra phiên bản mới") { Task { await check() } }
                .disabled(checking)
            if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
            if let updateURL { Link("Mở bản cập nhật", destination: updateURL) }
            Text("Bản cập nhật cần được cài qua công cụ đã ký ứng dụng để giữ dữ liệu hiện tại.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    @MainActor private func check() async {
        checking = true; updateURL = nil
        defer { checking = false }
        do {
            let api = URL(string: "https://api.github.com/repos/pythonltn2000/Anpinime/actions/workflows/build-ipa-light.yml/runs?status=success&per_page=10")!
            var request = URLRequest(url: api); request.timeoutInterval = 15
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let runs = root["workflow_runs"] as? [[String: Any]] else { throw URLError(.badServerResponse) }
            let current = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
            var inspected = 0
            for run in runs {
                guard let sha = run["head_sha"] as? String, sha.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
                      let rawLink = run["html_url"] as? String, let link = URL(string: rawLink), link.scheme == "https", link.host == "github.com" else { continue }
                var sourceRequest = URLRequest(url: URL(string: "https://raw.githubusercontent.com/pythonltn2000/Anpinime/" + sha + "/AnyAnime/Info.plist")!)
                sourceRequest.timeoutInterval = 10
                let (plist, reply) = try await URLSession.shared.data(for: sourceRequest)
                guard (reply as? HTTPURLResponse)?.statusCode == 200, plist.count < 100_000,
                      let info = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
                      let build = Int(info["CFBundleVersion"] as? String ?? "") else { continue }
                inspected += 1
                if build > current {
                    message = "Có phiên bản \(info["CFBundleShortVersionString"] as? String ?? "") (\(build))."
                    updateURL = link; return
                }
            }
            guard inspected > 0 else { throw URLError(.badServerResponse) }
            message = "Chưa có build mới hơn bản đang cài."
        } catch { message = "Chưa kiểm tra được bản cập nhật. Hãy thử lại sau." }
    }
}

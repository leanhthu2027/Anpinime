import SwiftUI

struct AetherSettingsSection: View {
    @EnvironmentObject private var service: AnimeService
    @State private var domain = UserDefaults.standard.string(forKey: AetherDomainPolicy.manualKey) ?? ""
    @State private var metadataCredential = ""
    @State private var metadataConfigured = AetherMetadataSettings.configured
    @State private var metadataMessage = ""
    @State private var message = ""
    @State private var saving = false
    var body: some View {
        Section {
            SecureField("TMDB API Read Access Token", text: $metadataCredential)
                .textInputAutocapitalization(.never).disableAutocorrection(true)
                .accessibilityIdentifier("vip.settings.tmdb-token")
            Text(metadataConfigured ? "Đã cấu hình danh mục phim." : "Chưa cấu hình truy cập danh mục TMDB.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Lưu truy cập danh mục") {
                guard !metadataCredential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    metadataMessage = "Nhập token mới để thay đổi; token hiện tại vẫn được giữ."
                    return
                }
                do {
                    try AetherMetadataSettings.saveCredential(metadataCredential)
                    metadataCredential = ""; metadataConfigured = AetherMetadataSettings.configured
                    metadataMessage = "Đã lưu vào Keychain."
                    Task { await service.loadHome(forceDomainRefresh: true) }
                } catch { metadataMessage = error.localizedDescription }
            }.disabled(service.homeLoading)
            if metadataConfigured {
                Button("Xóa token đã lưu", role: .destructive) {
                    do {
                        try AetherMetadataSettings.saveCredential("")
                        metadataCredential = ""; metadataConfigured = AetherMetadataSettings.configured
                        metadataMessage = "Đã xóa token khỏi Keychain."
                        Task { await service.loadHome(forceDomainRefresh: true) }
                    } catch { metadataMessage = error.localizedDescription }
                }
            }
            if !metadataMessage.isEmpty { Text(metadataMessage).font(.footnote).foregroundStyle(.secondary) }
            Link("Lấy token truy cập TMDB", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
            Divider()
            TextField("Tự động · https://aether.st", text: $domain)
                .keyboardType(.URL).textInputAutocapitalization(.never).disableAutocorrection(true)
                .accessibilityIdentifier("aether.settings.domain")
            Button("Lưu tên miền Aether") {
                saving = true
                Task { @MainActor in
                    defer { saving = false }
                    do {
                        try await AetherDomainResolver.shared.setManualDomain(domain)
                        message = "Đã lưu. Tên miền mới áp dụng lần mở video tiếp theo; video đang phát giữ nguyên kết nối."
                    } catch { message = error.localizedDescription }
                }
            }.disabled(saving)
            if saving { ProgressView() }
            if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
            Link("Danh sách tên miền chính thức", destination: AetherDomainPolicy.directory)
        } header: { Text(ContentSource.aether.title) }
          footer: {
              Text("Danh mục, tìm kiếm và thông tin phim dùng metadata TMDB trong giao diện Anpinime. Video và các chức năng phụ đề dùng Aether. Để trống tên miền để tự động tìm máy chủ. This product uses the TMDB API but is not endorsed or certified by TMDB.")
          }
    }
}

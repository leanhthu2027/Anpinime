import SwiftUI

struct AetherSettingsSection: View {
    @State private var domain = UserDefaults.standard.string(forKey: AetherDomainPolicy.manualKey) ?? ""
    @State private var message = ""
    @State private var saving = false
    var body: some View {
        Section {
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

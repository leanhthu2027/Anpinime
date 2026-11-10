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
                        message = "Đã lưu. Tên miền mới áp dụng khi bạn kết thúc phiên Aether và mở lại."
                    } catch { message = error.localizedDescription }
                }
            }.disabled(saving)
            if saving { ProgressView() }
            if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
            Link("Danh sách tên miền chính thức", destination: AetherDomainPolicy.directory)
        } header: { Text("Aether") }
          footer: { Text("Để trống để tìm tên miền tự động. Danh sách và tìm kiếm nằm trong website Aether. Chọn phụ đề hoặc dùng nút dịch của website nếu có; PiP tùy thuộc video và iOS. Đổi tên miền sẽ không di chuyển phiên đang phát.") }
    }
}

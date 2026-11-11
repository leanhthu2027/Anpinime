import SwiftUI

struct AppSettingsView: View {
    @EnvironmentObject private var service: AnimeService
    var onChooseLibrary: (() -> Void)? = nil
    @AppStorage("AnPinime.automaticPiP") private var automaticPiP = true
    @AppStorage("AnPinime.autoNext") private var autoNext = true
    @AppStorage("AnPinime.rememberSpeed") private var rememberSpeed = true
    @AppStorage("AnPinime.skipSeconds") private var skipSeconds = 10
    @State private var animeURL = UserDefaults.standard.string(forKey: AnimeSiteConfiguration.customURLKey) ?? ""
    @State private var animeSourceMessage = ""

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image("AppLogo").resizable().scaledToFit().frame(width: 120, height: 120)
                    Text("AnPinime").font(.largeTitle.bold())
                    Text("Anime và điện ảnh. Một nơi dành cho bạn.")
                        .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 16)
            }
            Section("Trải nghiệm xem") {
                Toggle("PiP khi rời ứng dụng", isOn: $automaticPiP)
                Toggle("Tự phát tập tiếp theo", isOn: $autoNext)
                Toggle("Ghi nhớ tốc độ phát", isOn: $rememberSpeed)
                Picker("Tua nhanh / tua lại", selection: $skipSeconds) {
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) giây").tag($0) }
                }
            }
            Section("Kết nối") {
                LabeledContentCompat(title: "Nguồn đang chọn", value: service.source.subtitle)
                if let onChooseLibrary {
                    Button(action: onChooseLibrary) { Label("Đổi thư viện", systemImage: "square.grid.2x2") }
                }
                if !service.source.isMovie { LabeledContentCompat(title: "Máy chủ", value: service.baseURL.host ?? "Đang kết nối") }
                Button("Làm mới danh sách và kết nối") { Task { await service.loadHome(forceDomainRefresh: true) } }
                    .disabled(service.homeLoading)
            }
            if service.source == .anime {
                Section {
                    TextField("https://…", text: $animeURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).disableAutocorrection(true)
                    Button("Lưu website anime") {
                        let value = animeURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !value.isEmpty && AnimeSiteConfiguration.normalizedBase(value) == nil {
                            animeSourceMessage = "Nhập địa chỉ gốc HTTPS của website, không kèm đường dẫn hoặc tham số."
                            return
                        }
                        UserDefaults.standard.set(value, forKey: AnimeSiteConfiguration.customURLKey)
                        animeSourceMessage = value.isEmpty ? "Đã chọn tìm tên miền tự động." : "Đã lưu website anime."
                        Task { await service.reloadAnimeSource() }
                    }.disabled(service.homeLoading)
                    if !animeSourceMessage.isEmpty { Text(animeSourceMessage).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("Website anime") }
                  footer: { Text("Địa chỉ này dùng chung cho danh sách, tìm kiếm, thông tin, tập phim và lịch chiếu anime. Để trống để tìm tên miền tự động.") }
            }
            if service.source == .aether { AetherSettingsSection() }
            AppUpdateSection()
            Section("Giới thiệu") {
                LabeledContentCompat(title: "Ứng dụng", value: "AnPinime")
                LabeledContentCompat(title: "Phiên bản", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.1.0")
                LabeledContentCompat(title: "Tác giả", value: "KingLTN")
                Text("Khám phá anime và phim, chọn nguồn yêu thích và tận hưởng từng khung hình.")
                    .font(.footnote).foregroundColor(.secondary)
                Link(destination: URL(string: "https://t.me/kingltnn")!) {
                    HStack(spacing: 12) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Color(red: 0.13, green: 0.67, blue: 0.91), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Telegram").font(.headline)
                            Text("@kingltnn").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                    .cinemaGlass(cornerRadius: 20, interactive: true)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Cài đặt")
    }
}

private struct LabeledContentCompat: View {
    let title: String
    let value: String
    var body: some View { HStack { Text(title); Spacer(); Text(value).foregroundColor(.secondary) } }
}


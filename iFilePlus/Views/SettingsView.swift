import SwiftUI

struct SettingsView: View {
    @State private var notificationStatus: String?
    var body: some View {
        List {
            Section("应用") {
                HStack(spacing: 12) {
                    Image("AstroGateLogo").resizable().frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("AstroGate 管家")
                            .font(.headline)
                        Text("文件 · SFTP · SSH · Codex · OpenClaw")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                LabeledContent("版本", value: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") + ")")
                LabeledContent("最低系统", value: "iOS 17.0")
            }

            Section("AI") { NavigationLink("AI 中转站") { AISettingsView() } }

            Section("Codex 完成提醒") {
                Button("开启完成通知") { Task { do { notificationStatus = try await CodexNotifications.shared.enable() ? "已开启" : "请在 iOS 设置中允许通知" } catch { notificationStatus = error.localizedDescription } } }
                if let notificationStatus { Text(notificationStatus).font(.caption) }
                Text("当前为连接期间的完成提醒；App 被系统挂起后，会在重新连接时补查结果。").font(.caption).foregroundStyle(.secondary)
            }

        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

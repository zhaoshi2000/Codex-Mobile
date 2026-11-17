import SwiftUI
import UserNotifications

struct SettingsView: View {
    @AppStorage("codex.voice.preferLocal.v1") private var preferLocalVoice = true
    private var version: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") + ")" }
    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image("AstroGateLogo").resizable().frame(width: 54, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("AstroGate").font(.title3.weight(.semibold))
                        Text("随时继续你的 Codex 工作").font(.caption).foregroundStyle(.secondary)
                        Text(version).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }.padding(.vertical, 8)
            }
            Section("Codex") {
                NavigationLink { CodexVoiceSettingsView() } label: {
                    SettingsRow(title: "语音输入", subtitle: preferLocalVoice ? "手机本地识别" : "服务器 CPU 识别", icon: "waveform", color: .indigo)
                }
                NavigationLink { CodexNotificationSettingsView() } label: {
                    SettingsRow(title: "完成提醒", subtitle: "任务结束时通知我", icon: "bell.badge", color: .orange)
                }
            }
            Section("服务") {
                NavigationLink { AISettingsView() } label: {
                    SettingsRow(title: "AI 中转站", subtitle: "接口地址、模型与 API Key", icon: "network", color: .teal)
                }
            }
            Section {
                LabeledContent("系统要求", value: "iOS 17.0 及以上").font(.footnote).foregroundStyle(.secondary)
            } footer: { Text("电脑连接在“连接”管理，文件和服务器入口在“服务”。") }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("设置").navigationBarTitleDisplayMode(.large)
    }
}

private struct SettingsRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 17, weight: .medium)).foregroundStyle(color)
                .frame(width: 36, height: 36).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 16, weight: .medium)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 7)
    }
}

struct CodexVoiceSettingsView: View {
    @AppStorage("codex.voice.preferLocal.v1") private var preferLocal = true
    var body: some View {
        List {
            Section {
                voiceOption(local: true, title: "手机本地", subtitle: "中文离线识别，无需中转", icon: "iphone")
                voiceOption(local: false, title: "服务器 CPU", subtitle: "通过已连接的电脑转发识别", icon: "desktopcomputer")
            } header: { Text("识别方式") } footer: {
                Text(preferLocal ? "使用手机的语音识别能力，需要麦克风、语音识别权限和中文离线资源。" : "需要电脑、中转及语音识别服务在线。录音会发送到已配置的 CPU 服务处理。")
            }
            Section("使用方式") {
                Label("按住说话，松开转成文字", systemImage: "hand.tap")
                Label("上滑取消本次录音", systemImage: "arrow.up")
                Label("识别后可编辑，确认后再发送", systemImage: "square.and.pencil")
            }.font(.subheadline).foregroundStyle(.secondary)
        }.listStyle(.insetGrouped).navigationTitle("语音输入").navigationBarTitleDisplayMode(.inline)
    }
    private func voiceOption(local: Bool, title: String, subtitle: String, icon: String) -> some View {
        Button { preferLocal = local } label: {
            HStack {
                SettingsRow(title: title, subtitle: subtitle, icon: icon, color: .indigo)
                Spacer()
                if preferLocal == local { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(preferLocal == local ? .isSelected : [])
    }
}

private struct CodexNotificationSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var status = "正在读取…"
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        List {
            Section {
                SettingsRow(title: "Codex 完成提醒", subtitle: status, icon: "bell.badge", color: .orange)
                Button {
                    busy = true
                    Task {
                        defer { busy = false }
                        do { _ = try await CodexNotifications.shared.enable(); error = nil; await refresh() }
                        catch { self.error = error.localizedDescription }
                    }
                } label: { HStack { Text("开启完成通知"); Spacer(); if busy { ProgressView() } } }.disabled(busy)
                Button("前往系统通知设置") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
            } footer: { Text("连接期间会提醒任务结果；App 被系统挂起后，重新连接时会补查结果。") }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }.listStyle(.insetGrouped).navigationTitle("完成提醒").navigationBarTitleDisplayMode(.inline)
            .task { await refresh() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await refresh() } } }
    }
    private func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: status = "已允许通知"
        case .denied: status = "未允许，请在系统设置中开启"
        default: status = "尚未开启"
        }
    }
}

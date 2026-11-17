import SwiftUI

struct ZeroTierSettingsView: View {
    @ObservedObject private var node = ZeroTierService.shared
    @State private var busy = false
    var body: some View {
        Form {
            Section {
                Toggle("启用 ZeroTier", isOn: Binding(get: { node.enabled }, set: { value in
                    busy = true
                    Task { await node.setEnabled(value); busy = false }
                })).disabled(busy)
                LabeledContent("状态", value: node.status)
            } footer: { Text("由 AstroGate 内置运行，无需另外安装 ZeroTier App。关闭后停止直连，服务器中转仍可使用。") }
            Section("网络") {
                TextField("16 位网络 ID", text: $node.networkID).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(node.enabled)
                if !node.nodeID.isEmpty {
                    LabeledContent("本机节点") {
                        Button { UIPasteboard.general.string = node.nodeID } label: {
                            HStack { Text(node.nodeID).monospaced(); Image(systemName: "doc.on.doc") }
                        }.buttonStyle(.borderless)
                    }
                }
                if !node.address.isEmpty { LabeledContent("网络地址", value: node.address) }
            }
            Section {
                Text("首次加入私有网络后，在该网络的管理后台授权上方节点。电脑也需要加入同一网络。")
                Text("FTP 可在连接设置中选择直连；主机文件和网页可选择 ZeroTier 或服务器中转。")
            }.font(.footnote).foregroundStyle(.secondary)
            Section {
                NavigationLink("开源许可") {
                    ScrollView {
                        Text((Bundle.main.url(forResource: "ZeroTierNotices", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? "许可文件不可用")
                            .font(.caption).textSelection(.enabled).padding()
                    }.navigationTitle("开源许可")
                }
            }
        }.navigationTitle("ZeroTier").navigationBarTitleDisplayMode(.inline)
    }
}

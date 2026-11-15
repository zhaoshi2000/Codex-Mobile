import SwiftUI

struct AISettingsView: View {
    @State private var address = ServerAIConfiguration.saved.address
    @State private var model = ServerAIConfiguration.saved.model
    @State private var apiKey = KeychainStore.get(account: ServerAIConfiguration.keyAccount) ?? ""
    @State private var notice: String?
    @State private var checking = false
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var modelNotice: String?
    @State private var modelRequest = UUID()
    @State private var choosingModel = false
    var body: some View {
        Form {
            Section {
                TextField("https://你的地址/v1", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("API Key", text: $apiKey).textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("AI 中转站") } footer: { Text("用于服务器 AI 助手，支持兼容 OpenAI 的 Chat Completions 流式接口及工具调用。聊天和选定命令的结果会发送到此地址。API Key 保存在本机钥匙串，与 SSH 私钥分开。") }
            Section {
                Button { choosingModel = true } label: {
                    HStack {
                        Text("选择模型")
                        Spacer()
                        Text(model.isEmpty ? "尚未选择" : model).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.right").font(.caption)
                    }
                }.disabled(models.isEmpty || loadingModels)
                Button { modelRequest = UUID() } label: {
                    HStack { Text(loadingModels ? "正在获取模型…" : (models.isEmpty ? "获取模型列表" : "刷新模型列表")); Spacer(); if loadingModels { ProgressView() } }
                }.disabled(!canLoadModels || loadingModels)
                if let modelNotice { Text(modelNotice).font(.caption).foregroundStyle(.secondary) }
                TextField("手动填写模型名称", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("模型") } footer: { Text("填好地址和 API Key 后自动获取模型。选择后点击保存；列表中的模型是否支持聊天和工具调用，以中转站实际支持为准。") }
            Section {
                Button("保存") { do { try config.save(key: apiKey); notice = "已保存" } catch { notice = error.localizedDescription } }
                Button(checking ? "正在测试…" : "测试模型连接") { Task { checking = true; defer { checking = false }; do { _ = try await ServerAIClient.complete(config: config, key: apiKey.trimmingCharacters(in: .whitespacesAndNewlines), messages: [["role": "user", "content": "只回复 OK"]], tools: true, onText: { _ in }); notice = "流式接口可用；请保存配置" } catch { notice = error.localizedDescription } } }.disabled(checking)
                if let notice { Text(notice).font(.caption).textSelection(.enabled) }
            } footer: { Text("测试会发起一次 AI 请求，可能消耗中转站额度。") }
        }.navigationTitle("AI 中转站")
        .onChange(of: address) { _, _ in resetModelList() }
        .onChange(of: apiKey) { _, _ in resetModelList() }
        .task(id: modelRequest) { await loadModels() }
        .sheet(isPresented: $choosingModel) {
            NavigationStack { ServerAIModelPicker(models: models, selection: $model) }
        }
    }
    private var canLoadModels: Bool { (try? ServerAIProtocol.modelsEndpoint(address)) != nil && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func resetModelList() { models = []; modelNotice = nil; loadingModels = false; choosingModel = false; modelRequest = UUID() }
    @MainActor private func loadModels() async {
        guard canLoadModels else { return }
        let requestID = modelRequest, requestedAddress = address, requestedKey = apiKey
        do {
            // Debounce edits; never apply a response for an older address or key.
            try await Task.sleep(nanoseconds: 700_000_000)
            try Task.checkCancellation()
            loadingModels = true; modelNotice = nil
            let available = try await ServerAIClient.models(address: requestedAddress, key: requestedKey)
            try Task.checkCancellation()
            guard requestID == modelRequest else { return }
            models = available
            modelNotice = "已获取 \(available.count) 个模型" + (model.isEmpty ? "，请选择模型" : (available.contains(model) ? "" : "；当前填写的模型不在此列表中"))
        } catch {
            guard !Task.isCancelled, requestID == modelRequest else { return }
            modelNotice = error.localizedDescription
        }
        if requestID == modelRequest { loadingModels = false }
    }
    private var config: ServerAIConfiguration { ServerAIConfiguration(address: address.trimmingCharacters(in: .whitespacesAndNewlines), model: model.trimmingCharacters(in: .whitespacesAndNewlines)) }
}
private struct ServerAIModelPicker: View {
    let models: [String]
    @Binding var selection: String
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss
    private var filtered: [String] { search.isEmpty ? models : models.filter { $0.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        List {
            ForEach(filtered, id: \.self) { model in
                Button { selection = model; dismiss() } label: {
                    HStack { Text(model).foregroundStyle(.primary); Spacer(); if selection == model { Image(systemName: "checkmark") } }
                }
            }
            if filtered.isEmpty { Text("没有匹配的模型").foregroundStyle(.secondary) }
        }
        .searchable(text: $search, prompt: "搜索模型")
        .navigationTitle("选择模型").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
    }
}
struct ServerAIView: View {
    let connection: ServerConnection
    @EnvironmentObject private var store: ConnectionStore
    @StateObject private var service: ServerAIService
    @State private var draft = ""
    @State private var confirming: ServerAITool?
    init(connection: ServerConnection) { self.connection = connection; _service = StateObject(wrappedValue: ServerAIService(connection: connection)) }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Image(systemName: service.connected ? "checkmark.shield" : "wifi.slash"); Text(service.status); Spacer(); if service.busy { ProgressView() } }.font(.caption).foregroundStyle(.secondary).padding()
            if let error = service.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal) }
            if !service.connected { Button("连接 SSH") { Task { await service.connect(store: store) } }.disabled(service.busy) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if service.messages.isEmpty {
                            Text("向 AI 描述服务器任务，确认命令后执行。").foregroundStyle(.secondary)
                            Button("检查并安装 OpenClaw") { service.send("帮我检查这台服务器，若尚未安装 OpenClaw，请按官方方式安装。每步执行后检查结果，不覆盖已有配置，最后说明 Gateway 是否已可用。") }.disabled(!service.connected || service.busy)
                        }
                        ForEach(service.messages) { message in
                            VStack(alignment: .leading, spacing: 6) { Text(message.role).font(.caption.bold()).foregroundStyle(.secondary); if message.role == "服务器" { Text(message.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } else { CodexMarkdownView(text: message.text).textSelection(.enabled) } }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(message.role == "你" ? Color.blue.opacity(0.1) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        }
                        if let tool = service.pendingTools.first {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("待执行命令", systemImage: "terminal").font(.headline)
                                Text(tool.reason).font(.subheadline)
                                Text(tool.command ?? "无效命令").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                HStack { Button("查看并执行") { confirming = tool }; Spacer(); Button("拒绝", role: .cancel) { service.reject(tool) } }.disabled(service.busy || !service.connected)
                            }.padding().background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        }
                        Color.clear.frame(height: 1).id("end")
                    }.padding()
                }.onChange(of: service.messages.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            HStack {
                TextField("例如：检查并安装 OpenClaw", text: $draft, axis: .vertical).lineLimit(1...5).textFieldStyle(.roundedBorder)
                if service.busy { Button { service.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2) } }
                Button { let text = draft; draft = ""; service.send(text) } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }.disabled(!service.connected || service.busy || !service.pendingTools.isEmpty || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding()
        }
        .navigationTitle(connection.name + " · AI").navigationBarTitleDisplayMode(.inline)
        .toolbar { Menu { NavigationLink("AI 中转站设置") { AISettingsView() }; NavigationLink("SSH 终端") { SSHTerminalView(connection: connection) }; NavigationLink("OpenClaw 聊天") { OpenClawView(connection: connection) } } label: { Image(systemName: "ellipsis.circle") } }
        .task { await service.connect(store: store) }
        .onDisappear { service.disconnect() }
        .sheet(item: $confirming) { tool in
            NavigationStack { ScrollView { VStack(alignment: .leading, spacing: 18) { Text("服务器：" + connection.address).font(.headline); Text(tool.reason); Text(tool.command ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled); Text("执行后，命令输出会发送给设置中的 AI 中转站。仅执行你理解并同意的命令。").font(.caption).foregroundStyle(.secondary); Button("在此服务器执行") { confirming = nil; service.approve(tool) }.buttonStyle(.borderedProminent).disabled(!service.connected || service.busy) }.padding() }.navigationTitle("确认服务器操作").toolbar { Button("取消") { confirming = nil } } }
        }
        .alert("信任 SSH 服务器？", isPresented: $service.showTrust) { Button("取消", role: .cancel) {}; Button("信任并连接") { Task { await service.trust(store: store) } } } message: { Text(service.fingerprint) }
    }
}

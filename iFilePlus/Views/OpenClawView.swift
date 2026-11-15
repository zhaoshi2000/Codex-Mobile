import SwiftUI

struct OpenClawView: View {
    let connection: ServerConnection
    @EnvironmentObject private var store: ConnectionStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: OpenClawService
    @State private var draft = ""
    @State private var showSessions = false
    init(connection: ServerConnection) { self.connection = connection; _model = StateObject(wrappedValue: OpenClawService(connection: connection)) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(model.connected ? "SSH 已连接" : "SSH 未连接", systemImage: model.connected ? "checkmark.circle" : "wifi.slash")
                Spacer()
                Text(model.running ? connection.chatAlias + " 正在处理…" : connection.chatAlias)
            }.font(.caption).foregroundStyle(.secondary).padding()
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal) }
            if !model.connected { Button(model.busy ? "正在连接…" : "连接 OpenClaw") { Task { await model.connect(store: store) } }.disabled(model.busy).padding() }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(model.messages) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(message.role == "user" ? "你" : connection.chatAlias).font(.caption.bold()).foregroundStyle(.secondary)
                                CodexMarkdownView(text: message.text).textSelection(.enabled)
                                if let status = message.delivery { Text(status).font(.caption).foregroundStyle(.secondary) }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(message.role == "user" ? Color.blue.opacity(0.1) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        }
                        Color.clear.frame(height: 1).id("end")
                    }.padding()
                }.onChange(of: model.messages.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            if model.uncertain {
                HStack { Button("核实送达") { Task { await model.refresh() } }; Button("重试原消息") { Task { await model.send("") } }; Button("已核实，清除") { model.clearPending() } }.font(.caption).disabled(model.sending)
            }
            HStack {
                TextField("发给 " + connection.chatAlias + "…", text: $draft, axis: .vertical).lineLimit(1...6).textFieldStyle(.roundedBorder)
                if model.running { Button { Task { await model.stop() } } label: { Image(systemName: "stop.circle.fill").font(.title2) } }
                Button { let text = draft; draft = ""; Task { await model.send(text) } } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    .disabled(!model.connected || model.sending || model.deliveryPending || model.running || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding()
        }
        .navigationTitle(connection.name + " · " + connection.chatAlias).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button("选择会话") { showSessions = true }.disabled(!model.connected || model.sending || model.deliveryPending)
                Button("重新连接") { Task { await model.connect(store: store) } }.disabled(model.busy || model.sending)
            } label: { Image(systemName: "ellipsis.circle") }
        }
        .sheet(isPresented: $showSessions) {
            NavigationStack { List(model.sessions) { row in Button { showSessions = false; Task { await model.select(row.id) } } label: { HStack { Text(row.title); Spacer(); if row.active { ProgressView() }; if row.id == model.selected { Image(systemName: "checkmark") } } } }.navigationTitle("OpenClaw 会话").task { do { try await model.loadSessions() } catch { model.error = error.localizedDescription } }.toolbar { Button("完成") { showSessions = false } } }
        }
        .alert("信任 SSH 服务器？", isPresented: $model.showTrust) {
            Button("取消", role: .cancel) { model.showTrust = false }
            Button("信任并连接") { Task { await model.trust(store: store) } }
        } message: { Text(model.fingerprint) }
        .task {
            await model.connect(store: store)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                if Task.isCancelled { break }
                if scenePhase == .active && !model.sending { await model.refresh() }
            }
        }
        .onDisappear { Task { await model.disconnect() } }
        .onChange(of: scenePhase) { _, phase in if phase == .active && !model.connected { Task { await model.connect(store: store) } } }
    }
}

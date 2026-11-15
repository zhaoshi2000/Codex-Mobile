import SwiftUI

struct SSHTerminalView: View {
    let connection: ServerConnection
    @EnvironmentObject private var store: ConnectionStore
    @StateObject private var model: SSHTerminalModel

    init(connection: ServerConnection) {
        self.connection = connection
        _model = StateObject(wrappedValue: SSHTerminalModel(connection: connection))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle()
                    .fill(model.isConnected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(model.isConnected ? "SSH 已连接" : "SSH 未连接")
                    .font(.caption)
                Spacer()
                Text("\(connection.host):\(connection.port)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color(uiColor: .secondarySystemBackground))

            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.output)
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.green)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .id("terminal-bottom")
                }
                .background(Color.black)
                .onChange(of: model.output) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("terminal-bottom", anchor: .bottom) }
                }
            }

            if model.isConnected {
                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            quickCommand("pwd")
                            quickCommand("ls -la")
                            quickCommand("df -h")
                            quickCommand("free -h")
                            quickCommand("whoami")
                            quickCommand("uname -a")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            terminalKey("ESC", title: "Esc")
                            terminalKey("TAB", title: "Tab")
                            terminalKey("CTRL-C", title: "Ctrl+C")
                            terminalKey("CTRL-D", title: "Ctrl+D")
                            terminalKey("UP", title: "↑")
                            terminalKey("DOWN", title: "↓")
                            terminalKey("LEFT", title: "←")
                            terminalKey("RIGHT", title: "→")
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    }
                }
                .background(Color(uiColor: .secondarySystemBackground))
            }

            HStack(spacing: 10) {
                TextField("输入 Linux 命令…", text: $model.command, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .onSubmit { Task { await model.runCommand() } }
                    .padding(10)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Button {
                    Task { await model.runCommand() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .disabled(!model.isConnected || model.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
            .background(Color(uiColor: .systemBackground))
        }
        .navigationTitle("SSH 终端")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    NavigationLink { ServerAIView(connection: store.connections.first(where: { $0.id == connection.id }) ?? connection) } label: { Label("AI 服务器助手", systemImage: "sparkles") }
                        NavigationLink { OpenClawView(connection: store.connections.first(where: { $0.id == connection.id }) ?? connection) } label: { Label(connection.chatAlias + " 聊天", systemImage: "bubble.left.and.bubble.right") }
                    if !model.history.isEmpty {
                        Section("最近命令") {
                            ForEach(Array(model.history.suffix(8).reversed()), id: \.self) { command in
                                Button(command) { model.command = command }
                            }
                        }
                    }
                    if model.isConnected {
                        Button("断开连接", systemImage: "xmark.circle", role: .destructive) {
                            Task { await model.disconnect() }
                        }
                    } else {
                        Button("重新连接", systemImage: "arrow.clockwise") {
                            Task {
                                await model.start(
                                    password: store.password(for: connection.id) ?? "",
                                    privateKey: store.privateKey(for: connection.id),
                                    store: store
                                )
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            await model.start(
                password: store.password(for: connection.id) ?? "",
                privateKey: store.privateKey(for: connection.id),
                store: store
            )
        }
        .confirmationDialog(
            "首次连接需要确认服务器身份",
            isPresented: $model.showHostKeyPrompt,
            titleVisibility: .visible
        ) {
            Button("信任此服务器并连接") { Task { await model.acceptHostKey(store: store) } }
            Button("取消", role: .cancel) { model.cancelHostKeyPrompt() }
        } message: {
            Text("服务器：\(connection.host):\(connection.port)\n指纹：\(model.pendingFingerprint)\n请核对服务器管理员提供的指纹。")
        }
        .alert("SSH 连接失败", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("确定", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
        .onDisappear { Task { await model.disconnect() } }
    }

    private func quickCommand(_ value: String) -> some View {
        Button(value) { model.command = value }
            .font(.caption.monospaced())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(uiColor: .tertiarySystemBackground))
            .clipShape(Capsule())
    }

    private func terminalKey(_ key: String, title: String) -> some View {
        Button(title) { model.sendControl(key) }
            .font(.caption2.monospaced().weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(uiColor: .tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

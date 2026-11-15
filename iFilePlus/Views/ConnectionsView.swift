import SwiftUI
import UniformTypeIdentifiers

enum ConnectionAddKind: String, Identifiable, CaseIterable {
    case sftp = "SFTP", ssh = "SSH", openClaw = "OpenClaw"
    var id: String { rawValue }
}

struct ConnectionsView: View {
    @EnvironmentObject private var store: ConnectionStore
    @State private var adding: ConnectionAddKind?
    @State private var editing: ServerConnection?
    @State private var deleting: ServerConnection?
    private var visible: [ServerConnection] { store.connections.filter { $0.type != .ftp } }
    var body: some View {
        List {
            if !visible.isEmpty {
                Section("服务器") {
                    ForEach(visible) { connection in
                        if connection.type == .sftp {
                            NavigationLink { RemoteBrowserView(connection: connection) } label: { serverLabel(connection) }
                                .contextMenu { actions(connection) }
                        } else {
                            NavigationLink { SSHTerminalView(connection: connection) } label: { serverLabel(connection) }
                                .contextMenu { actions(connection) }
                        }
                    }
                }
            }
        }
        .navigationTitle("远程连接")
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Menu { ForEach(ConnectionAddKind.allCases) { kind in Button("添加 " + kind.rawValue) { adding = kind } } }
            label: { Image(systemName: "plus.circle.fill").font(.title2) }
        } }
        .sheet(item: $adding) { kind in NavigationStack { ConnectionEditorView(defaultType: kind == .sftp ? .sftp : .ssh, openClawSetup: kind == .openClaw) } }
        .sheet(item: $editing) { connection in NavigationStack { ConnectionEditorView(connection: connection) } }
        .alert("删除连接", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) { if let deleting { store.delete(deleting) }; deleting = nil }
        } message: { Text("删除此连接及保存的登录信息？") }
    }
    private func serverLabel(_ connection: ServerConnection) -> some View {
        Label { VStack(alignment: .leading, spacing: 4) { Text(connection.name).font(.headline); Text(connection.address).font(.caption).foregroundStyle(.secondary) } }
        icon: { Image(systemName: connection.type == .sftp ? "folder" : "server.rack").foregroundStyle(.blue) }
    }
    @ViewBuilder private func actions(_ connection: ServerConnection) -> some View {
        Button("编辑连接", systemImage: "pencil") { editing = connection }
        Button("删除连接", systemImage: "trash", role: .destructive) { deleting = connection }
    }
}

struct ConnectionEditorView: View {
    private let existingConnection: ServerConnection?
    private let openClawSetup: Bool
    @State private var chatAlias = "OC"
    @State private var clawExecutable = "openclaw"
    @State private var clawContainer = ""
    @State private var clawSession = "agent:main:main"
    @EnvironmentObject private var store: ConnectionStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var type: ConnectionType = .sftp
    @State private var authMode: SSHAuthenticationMode = .password
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var password = ""
    @State private var privateKeyText = ""
    @State private var initialPath = "/"
    @State private var showPassword = false
    @State private var showKeyImporter = false
    @State private var showError = false
    @State private var errorMessage = ""

    init(connection: ServerConnection? = nil, defaultType: ConnectionType = .sftp, openClawSetup: Bool = false) {
        self.openClawSetup = openClawSetup
        _chatAlias = State(initialValue: connection?.openClawAlias ?? "OC")
        _clawExecutable = State(initialValue: connection?.openClawExecutable ?? "openclaw")
        _clawContainer = State(initialValue: connection?.openClawContainer ?? "")
        _clawSession = State(initialValue: connection?.openClawSession ?? "agent:main:main")
        existingConnection = connection
        _name = State(initialValue: connection?.name ?? "")
        _type = State(initialValue: connection?.type ?? defaultType)
        _authMode = State(initialValue: connection?.effectiveAuthenticationMode ?? .password)
        _host = State(initialValue: connection?.host ?? "")
        _port = State(initialValue: String(connection?.port ?? defaultType.defaultPort))
        _username = State(initialValue: connection?.username ?? "")
        _initialPath = State(initialValue: connection?.initialPath ?? "/")
    }

    private var needsPassword: Bool {
        type == .ftp || authMode == .password
    }

    var body: some View {
        Form {
            Section("连接类型") {
                Picker("协议", selection: $type) {
                    ForEach([ConnectionType.sftp, .ssh]) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: type) { _, newValue in
                    port = String(newValue.defaultPort)
                    if newValue == .ftp { authMode = .password }
                }
                Text(type.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("服务器信息") {
                TextField("连接名称，例如：公司服务器", text: $name)
                TextField("主机名或 IP 地址", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("端口", text: $port)
                    .keyboardType(.numberPad)
                TextField("用户名", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if type != .ftp {
                Section("SSH 认证方式") {
                    Picker("认证方式", selection: $authMode) {
                        ForEach(SSHAuthenticationMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            if needsPassword {
                Section("登录密码") {
                    if showPassword {
                        TextField("密码", text: $password)
                    } else {
                        SecureField("密码", text: $password)
                    }
                    Toggle("显示密码", isOn: $showPassword)
                }
            } else {
                Section("SSH 私钥") {
                    Button {
                        showKeyImporter = true
                    } label: {
                        Label(privateKeyText.isEmpty ? "导入私钥文件" : "重新导入私钥", systemImage: "key.horizontal")
                    }
                    if !privateKeyText.isEmpty {
                        Label("已导入私钥（保存在 iOS 钥匙串）", systemImage: "checkmark.shield.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Text(privateKeyTypeDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("支持未加密 OpenSSH Ed25519 / RSA 私钥，以及 PEM 格式 ECDSA P-256 / P-384 / P-521。带口令加密的私钥暂不支持。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if type == .ssh {
                Section("OpenClaw") {
                    TextField("聊天简称", text: $chatAlias)
                    TextField("命令或可执行文件路径", text: $clawExecutable).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Docker 容器名称（可选）", text: $clawContainer).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("默认会话", text: $clawSession).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
            Section("远程目录") {
                TextField("初始路径", text: $initialPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if type == .ftp {
                    LabeledContent("传输模式", value: "被动模式（EPSV / PASV）")
                }
            }

            if type == .ftp {
                Section {
                    Label("普通 FTP 不加密账号密码和文件内容。", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("如果服务器支持，优先使用 SFTP。当前版本实现普通 FTP 被动模式，不包含 FTPS。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(existingConnection == nil ? (openClawSetup ? "添加 OpenClaw" : "添加 " + type.rawValue) : "编辑服务器")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let existingConnection {
                password = store.password(for: existingConnection.id) ?? ""
                privateKeyText = store.privateKey(for: existingConnection.id) ?? ""
            }
        }
        .fileImporter(
            isPresented: $showKeyImporter,
            allowedContentTypes: [.plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    privateKeyText = try String(contentsOf: url, encoding: .utf8)
                } catch {
                    errorMessage = "无法读取私钥文件：\(error.localizedDescription)"
                    showError = true
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
                showError = true
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .fontWeight(.semibold)
            }
        }
        .alert("无法保存", isPresented: $showError) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }

    private var privateKeyTypeDescription: String {
        let key = privateKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.contains("OPENSSH PRIVATE KEY") { return "OpenSSH 私钥格式" }
        if key.contains("BEGIN EC PRIVATE KEY") || key.contains("BEGIN PRIVATE KEY") { return "PEM 私钥格式" }
        return "已读取文本文件，请确认它是受支持的私钥格式。"
    }

    private func save() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanKey = privateKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanHost.isEmpty, !cleanUser.isEmpty,
              let portNumber = Int(port), (1...65535).contains(portNumber) else {
            errorMessage = "请填写连接名称、主机、有效端口和用户名。"
            showError = true
            return
        }
        if needsPassword && password.isEmpty {
            errorMessage = "请填写登录密码。"
            showError = true
            return
        }
        if !needsPassword && cleanKey.isEmpty {
            errorMessage = "请导入 SSH 私钥文件。"
            showError = true
            return
        }

        let trustedKey = (existingConnection?.host == cleanHost && existingConnection?.port == portNumber)
            ? existingConnection?.trustedHostKey : nil
        let connection = ServerConnection(
            id: existingConnection?.id ?? UUID(),
            name: cleanName,
            type: type,
            host: cleanHost,
            port: portNumber,
            username: cleanUser,
            initialPath: initialPath.isEmpty ? "/" : initialPath,
            trustedHostKey: trustedKey,
            authenticationMode: authMode,
            openClawAlias: String(chatAlias.prefix(16)),
            openClawExecutable: clawExecutable.isEmpty ? "openclaw" : clawExecutable,
            openClawContainer: clawContainer,
            openClawSession: clawSession.isEmpty ? "agent:main:main" : clawSession
        )
        do {
            try store.upsert(connection, password: needsPassword ? password : "", privateKey: needsPassword ? nil : cleanKey)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

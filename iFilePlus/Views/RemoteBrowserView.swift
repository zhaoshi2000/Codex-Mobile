import SwiftUI
import UniformTypeIdentifiers

struct RemoteBrowserView: View {
    let connection: ServerConnection
    @EnvironmentObject private var store: ConnectionStore
    @StateObject private var model: RemoteBrowserModel
    @State private var showUploadImporter = false
    @State private var showCreateFolder = false
    @State private var showCreateFile = false
    @State private var showRename = false
    @State private var showDelete = false
    @State private var renameTarget: RemoteFileEntry?
    @State private var deleteTarget: RemoteFileEntry?

    init(connection: ServerConnection) {
        self.connection = connection
        _model = StateObject(wrappedValue: RemoteBrowserModel(connection: connection))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: connection.type.icon)
                    .foregroundStyle(.blue)
                Text(model.currentPath)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                Spacer()
                if model.isConnected {
                    Label("已连接", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else if model.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemBackground))

            if model.isTransferring || !model.transferStatus.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(model.transferStatus)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        if model.isTransferring {
                            Text("\(Int(model.transferProgress * 100))%")
                                .font(.caption.monospacedDigit())
                        }
                    }
                    if model.isTransferring {
                        ProgressView(value: model.transferProgress)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(uiColor: .tertiarySystemBackground))
            }

            List {
                if model.entries.isEmpty && !model.isLoading {
                    ContentUnavailableView(
                        model.isConnected ? "目录为空" : "正在连接服务器",
                        systemImage: model.isConnected ? "folder" : "network",
                        description: Text(model.isConnected ? "此目录没有文件。" : "请检查服务器地址和账号信息。")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(model.entries) { entry in
                        Button {
                            Task { await model.open(entry) }
                        } label: {
                            RemoteFileRowView(item: entry)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("重命名", systemImage: "pencil") {
                                renameTarget = entry
                                showRename = true
                            }
                            if !entry.isDirectory {
                                Button("下载到本地", systemImage: "arrow.down.doc") {
                                    Task { await model.download(entry) }
                                }
                            }
                            Button("删除", systemImage: "trash", role: .destructive) {
                                deleteTarget = entry
                                showDelete = true
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { await model.refresh() }
            .confirmationDialog("确认删除", isPresented: $showDelete, titleVisibility: .visible) {
                Button("取消", role: .cancel) { deleteTarget = nil }
                Button("删除", role: .destructive) {
                    if let deleteTarget { Task { await model.delete(deleteTarget) } }
                    deleteTarget = nil
                }
            } message: {
                Text("确定删除远程项目“\(deleteTarget?.name ?? "")”？")
            }
        }
        .navigationTitle(connection.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Task { await model.goUp() }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(model.currentPath == "/" || !model.isConnected)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showUploadImporter = true
                } label: {
                    Image(systemName: "arrow.up.doc")
                }
                .disabled(!model.isConnected)
                Menu {
                    if model.isConnected {
                        Button("新建文件夹", systemImage: "folder.badge.plus") { showCreateFolder = true }
                        Button("新建 TXT", systemImage: "doc.badge.plus") { showCreateFile = true }
                        Button("刷新目录", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                        Divider()
                        Button("断开连接", systemImage: "xmark.circle", role: .destructive) { Task { await model.disconnect() } }
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
        .fileImporter(isPresented: $showUploadImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    await model.upload(url)
                }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showCreateFolder) {
            NameInputSheet(title: "新建远程文件夹", placeholder: "文件夹名称") { name in
                Task { await model.createFolder(named: name) }
            }
        }
        .sheet(isPresented: $showCreateFile) {
            NameInputSheet(title: "新建远程 TXT", placeholder: "例如 notes.txt") { name in
                Task { await model.createTextFile(named: name) }
            }
        }
        .sheet(isPresented: $showRename) {
            NameInputSheet(
                title: "重命名远程项目",
                placeholder: "新名称",
                initialValue: renameTarget?.name ?? ""
            ) { name in
                guard let renameTarget else { return }
                Task { await model.rename(renameTarget, to: name) }
            }
        }
        .sheet(item: $model.editorDocument) { document in
            NavigationStack {
                TextEditorView(title: document.title, initialText: document.initialText, onSave: document.onSave)
            }
        }
        .confirmationDialog(
            "首次连接需要确认服务器身份",
            isPresented: $model.showHostKeyPrompt,
            titleVisibility: .visible
        ) {
            Button("信任此服务器并连接") { Task { await model.acceptHostKey(store: store) } }
            Button("取消", role: .cancel) { model.cancelHostKeyPrompt() }
        } message: {
            Text("服务器：\(connection.host):\(connection.port)\n指纹：\(model.pendingFingerprint)\n请核对服务器管理员提供的指纹。确认后才会发送账号密码。")
        }
        .alert("提示", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("确定", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
        .onDisappear { Task { await model.disconnect() } }
    }
}

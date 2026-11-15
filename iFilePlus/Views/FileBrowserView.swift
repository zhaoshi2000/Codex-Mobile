import SwiftUI
import UniformTypeIdentifiers

struct IPAFileActions: View {
    let url: URL

    var body: some View {
        if url.pathExtension.lowercased() == "ipa" {
            ShareLink(item: url) {
                Label("用全能签签名", systemImage: "signature")
            }
            .accessibilityHint("在系统应用列表选择全能签，将此 IPA 传入该应用")
        }
    }
}

struct FileBrowserView: View {
    let directory: URL
    var isRoot: Bool = false

    @EnvironmentObject private var connectionStore: ConnectionStore
    @State private var showAddServer = false
    @State private var editingServer: ServerConnection?
    @State private var items: [LocalFileItem] = []
    @State private var searchText = ""
    @State private var showCreateFolder = false
    @State private var showCreateFile = false
    @State private var showCustomFile = false
    @State private var editingTarget: LocalFileItem?
    @State private var extractTarget: LocalFileItem?
    @State private var showCreateMarkdown = false
    @State private var showImporter = false
    @State private var showRename = false
    @State private var showDelete = false
    @State private var renameTarget: LocalFileItem?
    @State private var deleteTarget: LocalFileItem?
    @State private var errorMessage: String?
    @State private var showError = false

    private var filteredItems: [LocalFileItem] {
        guard !searchText.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            if isRoot {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "iphone.gen3")
                            .font(.title2)
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("我的 iPhone")
                                .font(.headline)
                            Text("AstroGate 本地文件")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(items.count) 项")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

            }
            if isRoot && connectionStore.connections.contains(where: { $0.type == .sftp }) {
                Section("服务器目录") {
                    ForEach(connectionStore.connections.filter { $0.type == .sftp }) { server in
                        NavigationLink { RemoteBrowserView(connection: server) } label: {
                            Label { VStack(alignment: .leading, spacing: 4) {
                                Text(server.name).font(.headline)
                                Text(server.address + " · " + server.initialPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            } } icon: { Image(systemName: "externaldrive.connected.to.line.below").foregroundStyle(.blue) }
                        }.contextMenu { Button("编辑服务器", systemImage: "pencil") { editingServer = server } }
                    }
                }
            }

            Section(isRoot ? "文件" : directory.lastPathComponent) {
                if filteredItems.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "文件夹为空" : "没有匹配的文件",
                        systemImage: searchText.isEmpty ? "folder" : "magnifyingglass",
                        description: Text(searchText.isEmpty ? "使用右上角 + 新建文件或导入文件。" : "尝试其他关键词。")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(filteredItems) { item in
                        NavigationLink {
                            destination(for: item)
                        } label: {
                            FileRowView(item: item)
                        }
                        .contextMenu {
                            if !item.isDirectory {
                                Button("用文本编辑器打开", systemImage: "doc.text") { editingTarget = item }
                                if item.url.pathExtension.lowercased() == "zip" {
                                    Button("解压 ZIP", systemImage: "archivebox") { extractTarget = item }
                                }
                            }
                            Button("重命名", systemImage: "pencil") {
                                renameTarget = item
                                showRename = true
                            }
                            Button("复制", systemImage: "doc.on.doc") {
                                perform { try LocalFileService.duplicate(item.url) }
                            }
                            if !isRoot && item.url.deletingLastPathComponent().standardizedFileURL != LocalFileService.documentsDirectory.standardizedFileURL {
                                Button("移到工作目录", systemImage: "arrowshape.turn.up.right") {
                                    perform { try LocalFileService.moveToRoot(item.url) }
                                }
                            }
                            ShareLink(item: item.url) {
                                Label("分享", systemImage: "square.and.arrow.up")
                            }
                            Button("删除", systemImage: "trash", role: .destructive) {
                                deleteTarget = item
                                showDelete = true
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(isRoot ? "文件管理" : directory.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索文件和文件夹")
        .toolbar {
            if isRoot {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        DualPaneView()
                    } label: {
                        Image(systemName: "rectangle.split.2x1")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("新建文件", systemImage: "doc.badge.plus") { showCustomFile = true }
                    Button("新建文件夹", systemImage: "folder.badge.plus") { showCreateFolder = true }
                    if isRoot { Button("添加 SFTP 服务器", systemImage: "network.badge.shield.half.filled") { showAddServer = true } }
                    Divider()
                    Button("导入文件", systemImage: "square.and.arrow.down") { showImporter = true }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                }
            }
        }
        .task(id: directory) { load() }
        .onAppear { load() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("iFileDocumentsChanged"))) { _ in load() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): perform { try LocalFileService.importFiles(urls, into: directory) }
            case .failure(let error): show(error)
            }
        }
        .sheet(isPresented: $showAddServer) { NavigationStack { ConnectionEditorView(defaultType: .sftp) } }
        .sheet(item: $editingServer) { server in NavigationStack { ConnectionEditorView(connection: server) } }
        .sheet(isPresented: $showCreateFolder) {
            NameInputSheet(title: "新建文件夹", placeholder: "文件夹名称") { name in
                perform { try LocalFileService.createFolder(named: name, in: directory) }
            }
        }
        .sheet(isPresented: $showCreateFile) {
            NameInputSheet(title: "新建 TXT", placeholder: "例如 notes.txt") { name in
                perform { _ = try LocalFileService.createTextFile(named: name, in: directory) }
            }
        }
        .sheet(isPresented: $showCustomFile) {
            NameInputSheet(title: "新建文件", placeholder: "完整文件名，例如 config.ini、test.xyz 或无后缀") { name in
                perform { _ = try LocalFileService.createFile(named: name, in: directory) }
            }
        }
        .sheet(item: $editingTarget, onDismiss: load) { item in
            NavigationStack { LocalTextFileView(url: item.url) }
        }
        .sheet(item: $extractTarget, onDismiss: load) { item in
            NavigationStack { ZipExtractView(url: item.url) }
        }
        .sheet(isPresented: $showCreateMarkdown) {
            NameInputSheet(title: "新建 Markdown 文件", placeholder: "例如 notes.md") { name in
                perform { _ = try LocalFileService.createMarkdownFile(named: name, in: directory) }
            }
        }
        .sheet(isPresented: $showRename) {
            NameInputSheet(
                title: "重命名",
                placeholder: "新名称",
                initialValue: renameTarget?.name ?? ""
            ) { name in
                guard let target = renameTarget else { return }
                perform { try LocalFileService.rename(target.url, to: name) }
            }
        }
        .confirmationDialog("确认删除", isPresented: $showDelete, titleVisibility: .visible) {
            Button("取消", role: .cancel) { deleteTarget = nil }
            Button("删除", role: .destructive) {
                guard let target = deleteTarget else { return }
                perform { try LocalFileService.delete(target.url) }
                deleteTarget = nil
            }
        } message: {
            Text("将删除“\(deleteTarget?.name ?? "")”，此操作无法撤销。")
        }
        .alert("操作失败", isPresented: $showError) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    @ViewBuilder
    private func destination(for item: LocalFileItem) -> some View {
        if item.isDirectory {
            FileBrowserView(directory: item.url)
        } else if item.isTextFile {
            LocalTextFileView(url: item.url)
        } else {
            FileInfoView(item: item)
        }
    }

    private func load() {
        do {
            items = try LocalFileService.list(directory)
        } catch {
            show(error)
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            load()
        } catch {
            show(error)
        }
    }

    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
    }
}

private struct FileInfoView: View {
    let item: LocalFileItem

    var body: some View {
        Form {
            Section("文件信息") {
                LabeledContent("名称", value: item.name)
                LabeledContent("类型", value: item.url.pathExtension.uppercased().isEmpty ? "未知" : item.url.pathExtension.uppercased())
                LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                if let modified = item.modified {
                    LabeledContent("修改时间", value: modified.formatted(date: .long, time: .shortened))
                }
                LabeledContent("路径", value: item.url.path)
                    .textSelection(.enabled)
            }
            Section {
                IPAFileActions(url: item.url)
                if item.url.pathExtension.lowercased() != "ipa" { NavigationLink { LocalTextFileView(url: item.url) } label: {
                    Label("用文本编辑器打开", systemImage: "doc.text")
                } }
                if item.url.pathExtension.lowercased() == "zip" {
                    NavigationLink { ZipExtractView(url: item.url) } label: {
                        Label("解压到新文件夹", systemImage: "archivebox")
                    }
                }
                ShareLink(item: item.url) {
                    Label("分享文件", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

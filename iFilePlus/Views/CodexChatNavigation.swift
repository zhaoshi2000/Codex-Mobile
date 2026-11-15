import SwiftUI
import QuickLook

struct CodexDownloadCard: View {
    @ObservedObject var service: CodexConnectService
    @State private var preview: CodexPreviewFile?
    var body: some View {
        if let state = service.downloadState, !state.preview || state.active {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(state.title, systemImage: state.phase == .saved ? "checkmark.circle.fill" : state.phase == .failed ? "exclamationmark.circle.fill" : "arrow.down.circle")
                        .font(.subheadline.bold()).foregroundStyle(state.phase == .failed ? Color.red : state.phase == .saved ? Color.green : Color.accentColor)
                    Spacer()
                    if !state.active { Button { service.dismissDownload() } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭下载提示") }
                }
                Text(state.name).font(.caption).lineLimit(1).truncationMode(.middle)
                if state.active {
                    if let progress = state.progress { ProgressView(value: progress) } else { ProgressView() }
                    HStack {
                        Text(state.sizeLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        Button("取消") { service.cancelDownload() }.font(.caption).disabled(state.phase == .cancelling)
                    }
                } else if state.phase == .saved, let file = state.file {
                    Text("已保存到：文件 → Codex 下载").font(.caption).foregroundStyle(.secondary)
                    IPAFileActions(url: file).font(.subheadline)
                    HStack(spacing: 24) {
                        Button("打开文件", systemImage: "doc") { preview = CodexPreviewFile(url: file) }
                        ShareLink(item: file) { Label("分享 / 导出", systemImage: "square.and.arrow.up") }
                    }.font(.subheadline)
                } else if let error = state.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }.padding(12).background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .contain)
                .sheet(item: $preview) { item in
                    NavigationStack { CodexFilePreview(url: item.url).navigationTitle(item.url.lastPathComponent).navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { preview = nil } } } }
                }
        }
    }
}

struct CodexCommandRow: View {
    @ObservedObject var service: CodexConnectService
    let threadID: String
    let item: CodexChatMessage
    @State private var expanded = false
    @State private var detail: [String: Any]?
    @State private var error: String?
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
            VStack(alignment: .leading, spacing: 8) {
                if let detail {
                    Text(detail["command"] as? String ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    if let cwd = detail["cwd"] as? String, !cwd.isEmpty { Text(cwd).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
                    ScrollView(.horizontal) { Text((detail["output"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "暂无输出").font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    HStack {
                        Text(detail["status"] as? String == "inProgress" ? "执行中" : "执行结束")
                        if let code = detail["exitCode"] as? Int { Text("退出码：\(code)") }
                    }.font(.caption).foregroundStyle(.secondary)
                    if detail["truncated"] as? Bool == true { Text("仅显示末尾输出，完整记录可在电脑查看。").font(.caption2).foregroundStyle(.secondary) }
                } else if error == nil { ProgressView("读取命令详情…") }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }.padding(.vertical, 8)
            .task {
                repeat {
                    do { detail = try await service.request("commandDetails", ["threadId": threadID, "turnId": item.turnID ?? "", "itemId": item.id]); error = nil }
                    catch { self.error = error.localizedDescription; break }
                    if detail?["status"] as? String != "inProgress" { break }
                    try? await Task.sleep(for: .seconds(2))
                } while !Task.isCancelled && expanded
            }
            }
        } label: {
            Label(item.toolStatus == "inProgress" ? "正在运行命令" : "运行了命令", systemImage: "terminal").font(.caption).foregroundStyle(.secondary)
        }.tint(.secondary)
    }
}

struct CodexCommandGroup: View {
    @ObservedObject var service: CodexConnectService
    let threadID: String
    let items: [CodexChatMessage]
    @State private var expanded = false
    @State private var contentHeight: CGFloat = 0
    private let maximumHeight: CGFloat = 300
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(items) { item in CodexCommandRow(service: service, threadID: threadID, item: item) }
                    }
                    .padding(10)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.height
                    } action: { height in
                        contentHeight = height
                    }
                }
                .frame(height: min(contentHeight, maximumHeight))
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .clipped()
            }
        } label: {
            Label(items.contains(where: { $0.toolStatus == "inProgress" }) ? "正在执行 \(items.count) 个命令" : "执行了 \(items.count) 个命令", systemImage: "terminal").font(.caption).foregroundStyle(.secondary)
        }.tint(.secondary)
    }
}

struct CodexChatGroupView: View {
    @ObservedObject var service: CodexConnectService
    let threadID: String
    let group: CodexChatGroup
    let forking: Bool
    let openFile: (String) -> Void
    let fork: (CodexChatMessage) -> Void
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if group.isUser { Text("你").font(.caption.bold()).foregroundStyle(.blue) }
            ForEach(group.blocks) { block in
                if block.isCommands { CodexCommandGroup(service: service, threadID: threadID, items: block.items) }
                else if let message = block.items.first {
                    CodexMarkdownView(text: message.text).textSelection(.enabled)
                        .environment(\.openURL, OpenURLAction { url in
                            if url.scheme == "ifilepc", let data = Data(codexBase64URL: url.lastPathComponent), let path = String(data: data, encoding: .utf8) { openFile(path); return .handled }
                            if ["https", "http", "mailto"].contains(url.scheme ?? "") { return .systemAction }
                            return .discarded
                        })
                    if let delivery = message.delivery { Text(delivery).font(.caption).foregroundStyle(.secondary) }
                    if message.truncated { Text("长消息已截取，请在电脑查看完整内容。").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let reply = group.reply {
                HStack(spacing: 18) {
                    Button { UIPasteboard.general.string = group.text; copied = true } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }.accessibilityLabel("复制本轮回复")
                    if reply.turnID != nil { Button { fork(reply) } label: { Image(systemName: "arrow.triangle.branch") }.accessibilityLabel("创建分支").disabled(forking || !service.connected) }
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(group.isUser ? 12 : 0)
            .background(group.isUser ? Color.blue.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct CodexChatBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
struct CodexPreviewFile: Identifiable { let url: URL; var id: String { url.path } }
struct CodexFilePreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url) }
    func makeUIViewController(context: Context) -> QLPreviewController { let view = QLPreviewController(); view.dataSource = context.coordinator; return view }
    func updateUIViewController(_ view: QLPreviewController, context: Context) { context.coordinator.url = url; view.reloadData() }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(_ url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

struct CodexModelPicker: View {
    @ObservedObject var service: CodexConnectService
    let threadID: String
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section { Text("当前：" + (service.currentModel.isEmpty ? "正在读取…" : service.currentModel)).font(.subheadline)
                    if !service.currentEffort.isEmpty { Text("推理强度：" + service.currentEffort).font(.caption).foregroundStyle(.secondary) }
                    Text("使用电脑当前提供商的模型。任务运行期间切换，会用于后续轮次。").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(service.models) { model in
                    Button { Task { busy = true; defer { busy = false }; do { try await service.chooseModel(model.id, threadID: threadID); dismiss() } catch { self.error = error.localizedDescription } } } label: {
                        HStack { Text(model.title); Spacer(); if service.currentModel == model.id { Image(systemName: "checkmark") } }
                    }.disabled(busy)
                }
                if busy { ProgressView("正在切换…") }
                if service.models.isEmpty && !busy { Button("重新读取模型") { Task { await service.refreshModels(threadID) } } }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("选择模型").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(busy) } }
                .task { await service.refreshModels(threadID) }
        }
    }
}

struct CodexChatNavigation: View {
    @ObservedObject var service: CodexConnectService
    let currentID: String
    let select: (CodexRow) -> Void
    let exit: () -> Void
    @State private var projects: [CodexRow] = []
    @State private var pinned: [CodexRow] = []
    @State private var recent: [CodexRow] = []
    @State private var expanded: Set<String> = []
    @State private var projectsExpanded = false
    @State private var projectThreads: [String: [CodexRow]] = [:]
    @State private var projectCursors: [String: String] = [:]
    @State private var loadingProjects: Set<String> = []
    @State private var recentCursor: String?
    @State private var loading = false
    @State private var error: String?
    @State private var creating = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(service.device.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("新建对话", systemImage: "square.and.pencil") { creating = true }
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .padding(.horizontal, 16)
            List {
                Section { Button("返回设备列表", systemImage: "desktopcomputer") { exit() } }
                Section("置顶对话") {
                    ForEach(pinned) { thread in threadRow(thread) }
                    if pinned.isEmpty { Text("长按对话可置顶").font(.caption).foregroundStyle(.secondary) }
                }
                Section {
                    DisclosureGroup(isExpanded: $projectsExpanded) {
                    ForEach(projects) { project in
                        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(project.id) }, set: { open in
                            if open { expanded.insert(project.id); if projectThreads[project.id] == nil { Task { await loadProject(project.id) } } }
                            else { expanded.remove(project.id) }
                        })) {
                            ForEach(projectThreads[project.id] ?? []) { thread in threadRow(thread) }
                            if loadingProjects.contains(project.id) { ProgressView() }
                            if projectCursors[project.id] != nil { Button("查看更多（20 条）") { Task { await loadProject(project.id, more: true) } }.disabled(loadingProjects.contains(project.id)) }
                            if projectThreads[project.id]?.isEmpty == true { Text("暂无对话").foregroundStyle(.secondary) }
                        } label: {
                            HStack { Label(project.title, systemImage: "folder"); Spacer(); projectBadge(project.id) }
                        }
                    }
                    } label: {
                        HStack { Label("项目", systemImage: "folder"); Spacer(); Text("\(projects.count)").foregroundStyle(.secondary) }
                    }
                }
                Section("最近对话") {
                    ForEach(recent) { thread in threadRow(thread) }
                    if recentCursor != nil { Button("查看更多（20 条）") { Task { await loadRecent(more: true) } }.disabled(loading) }
                    if loading { ProgressView() }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .listStyle(.insetGrouped)
            .sheet(isPresented: $creating) { CodexNewChatView(service: service, projects: projects) { row in select(row) } }
            .refreshable { await load() }
            .task { await load(); while !Task.isCancelled { await service.refreshActivity(); try? await Task.sleep(for: .seconds(4)) } }
        }
    }
    private func threadRow(_ thread: CodexRow) -> some View {
        Button { select(thread) } label: {
            HStack(spacing: 10) {
                if thread.id == currentID { Image(systemName: "bubble.left.fill").font(.caption) }
                Text(thread.title).foregroundStyle(.primary).lineLimit(2)
                Spacer(minLength: 4)
                if service.activeTasks.contains(where: { $0.id == thread.id }) { Circle().fill(.green).frame(width: 8, height: 8).accessibilityLabel("正在运行") }
                else if service.unreadThreads.contains(thread.id) { Circle().fill(.blue).frame(width: 8, height: 8).accessibilityLabel("完成未读") }
            }
        }
        .contextMenu {
            Button(pinned.contains(where: { $0.id == thread.id }) ? "取消置顶" : "置顶对话", systemImage: "pin") { Task { await pin(thread) } }
        }
        .swipeActions(edge: .leading) { Button("置顶", systemImage: "pin") { Task { await pin(thread) } }.tint(.orange) }
    }
    @ViewBuilder private func projectBadge(_ id: String) -> some View {
        if service.runningProjects.contains(id) { Circle().fill(.green).frame(width: 8, height: 8).accessibilityLabel("项目有任务正在运行") }
        else if service.unreadProjects.contains(id) { Circle().fill(.blue).frame(width: 8, height: 8).accessibilityLabel("项目有已完成未读任务") }
    }
    private func rows(_ result: [String: Any]) -> [CodexRow] {
        (result["threads"] as? [[String: Any]] ?? []).compactMap { x in guard let id = x["id"] as? String else { return nil }; return CodexRow(id: id, title: x["title"] as? String ?? "对话") }
    }
    private func load() async {
        do {
            let data = try await service.request("navigation")
            projects = (data["projects"] as? [[String: Any]] ?? []).compactMap { x in guard let id = x["id"] as? String else { return nil }; return CodexRow(id: id, title: x["name"] as? String ?? "项目") }
            pinned = (data["pinned"] as? [[String: Any]] ?? []).compactMap { x in guard let id = x["id"] as? String else { return nil }; return CodexRow(id: id, title: x["title"] as? String ?? "对话") }
            service.unreadThreads = Set(data["unread"] as? [String] ?? [])
            await loadRecent()
            for id in expanded { await loadProject(id) }
        } catch { self.error = error.localizedDescription }
    }
    private func loadRecent(more: Bool = false) async {
        guard !loading else { return }; loading = true; defer { loading = false }
        do {
            var params: [String: Any] = ["limit": 20]; if more, let cursor = recentCursor { params["cursor"] = cursor }
            let result = try await service.request("threads", params); let page = rows(result)
            if more { recent += page.filter { row in !recent.contains(where: { $0.id == row.id }) } } else { recent = page }
            recentCursor = result["nextCursor"] as? String
        } catch { self.error = error.localizedDescription }
    }
    private func loadProject(_ id: String, more: Bool = false) async {
        guard !loadingProjects.contains(id) else { return }; loadingProjects.insert(id); defer { loadingProjects.remove(id) }
        do {
            var params: [String: Any] = ["projectId": id, "limit": 20]; if more, let cursor = projectCursors[id] { params["cursor"] = cursor }
            let result = try await service.request("threads", params); let page = rows(result)
            if more { let old = projectThreads[id] ?? []; projectThreads[id] = old + page.filter { row in !old.contains(where: { $0.id == row.id }) } } else { projectThreads[id] = page }
            projectCursors[id] = result["nextCursor"] as? String
        } catch { self.error = error.localizedDescription }
    }
    private func pin(_ thread: CodexRow) async {
        do {
            _ = try await service.request("pinThread", ["threadId": thread.id, "pinned": !pinned.contains(where: { $0.id == thread.id })]); await load()
        } catch { self.error = error.localizedDescription }
    }
}

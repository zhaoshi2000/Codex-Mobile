import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers
import ImageIO

struct CodexHomeView: View {
    @EnvironmentObject private var store: CodexDeviceStore
    @EnvironmentObject private var navigation: AppNavigation
    private var device: CodexDevice? {
        store.devices.first { $0.id == navigation.selectedDeviceID } ?? store.devices.first
    }
    var body: some View {
        if let device {
            CodexHostView(device: device)
        } else {
            ContentUnavailableView {
                Label("在手机继续 Codex 对话", systemImage: "terminal")
            } description: {
                Text("先连接一台运行 Codex 的电脑，即可查看项目、继续对话或新建对话。")
            } actions: {
                Button("连接电脑") { navigation.tab = .connections }.buttonStyle(.borderedProminent)
            }
            .navigationTitle("Codex")
        }
    }
}

struct CodexConnectView: View {
    @EnvironmentObject private var store: CodexDeviceStore
    @EnvironmentObject private var navigation: AppNavigation
    @State private var pairing = false
    @State private var renaming: CodexDevice?
    @State private var deviceName = ""
    var body: some View {
        List {
            Section {
                Label("连接电脑上的 Codex", systemImage: "desktopcomputer")
                Text("选择已绑定的设备进入 Codex，或扫码新建连接。").font(.footnote).foregroundStyle(.secondary)
            }
            Section("已绑定设备") {
                if store.devices.isEmpty { Text("点击右上角 + 扫码连接电脑").foregroundStyle(.secondary) }
                ForEach(store.devices) { device in
                    CodexDeviceConnectionRow(device: device) { navigation.open(device) }
                    .swipeActions {
                        Button("移除", role: .destructive) { store.remove(device) }
                        Button("重命名") { deviceName = device.displayName; renaming = device }.tint(.blue)
                    }
                    .contextMenu { Button("重命名", systemImage: "pencil") { deviceName = device.displayName; renaming = device } }
                }
            }
            Section {
                Text("电脑需保持 Codex 和连接程序运行。首次配对后无需重复扫码。移除设备只清除手机记录；撤销手机访问请在电脑端执行 revoke。").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("连接")
        .toolbar { Button { pairing = true } label: { Image(systemName: "plus") }.accessibilityLabel("新建 Codex 连接") }
        .sheet(isPresented: $pairing) { CodexPairView(store: store) { device in pairing = false; navigation.open(device) } }
        .alert("重命名设备", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("设备名称", text: $deviceName)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") { if let device = renaming { store.rename(device, to: deviceName) }; renaming = nil }
                .disabled(deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { Text("仅修改这台手机上的设备名称，连接保持不变。") }
    }
}

private struct CodexDeviceConnectionRow: View {
    let device: CodexDevice
    let open: () -> Void
    @ObservedObject private var service: CodexConnectService
    init(device: CodexDevice, open: @escaping () -> Void) {
        self.device = device; self.open = open
        _service = ObservedObject(wrappedValue: CodexConnectService.session(for: device))
    }
    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.displayName).foregroundStyle(.primary)
                    Text(service.connected ? "已连接 · 点击继续对话" : "点击连接 Codex").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if service.connected { Circle().fill(.green).frame(width: 8, height: 8).accessibilityLabel("已连接") }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct CodexActivitySection: View {
    let device: CodexDevice
    @StateObject private var service: CodexConnectService
    @Environment(\.scenePhase) private var scenePhase
    init(device: CodexDevice) { self.device = device; _service = StateObject(wrappedValue: CodexConnectService.session(for: device)) }
    var body: some View {
        Section("正在运行 · " + device.displayName) {
            ForEach(service.activeTasks) { thread in
                NavigationLink { CodexChatView(service: service, thread: thread) } label: {
                    HStack { ProgressView(); VStack(alignment: .leading, spacing: 4) { Text(service.title(for: thread)).lineLimit(2); Text(thread.path).font(.caption).foregroundStyle(.secondary) } }
                }
            }
            if !service.connected { Text(service.status).font(.caption).foregroundStyle(.secondary) }
            else if let error = service.activityError { Text(error).font(.caption).foregroundStyle(.secondary) }
            else if service.activeTasks.isEmpty { Text("暂无正在运行的任务").foregroundStyle(.secondary) }
            if service.activityLimited { Text("任务目录较大，当前已检查前 5000 个对话。").font(.caption).foregroundStyle(.secondary) }
        }
        .task {
            if !service.connected { await service.connect() }
            while !Task.isCancelled {
                if scenePhase == .active { await service.refreshActivity() }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

private struct CodexPairView: View {
    @ObservedObject var store: CodexDeviceStore
    var onPaired: (CodexDevice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var scanning = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section { Text("在电脑运行 AstroGate Connect，扫描生成的配对二维码。二维码两分钟内有效。"); Button { scanning = true } label: { Label("扫描电脑二维码", systemImage: "qrcode.viewfinder") } }
                Section("或粘贴配对链接") {
                    TextField("ifilecodex://pair?data=…", text: $link, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled().lineLimit(3...6)
                    Button("添加电脑") { add(link) }.disabled(link.isEmpty)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("连接电脑").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .sheet(isPresented: $scanning) { CodexQRScanner { result in scanning = false; switch result { case .success(let value): add(value); case .failure(let e): error = e.localizedDescription } }.ignoresSafeArea() }
        }
    }
    private func add(_ value: String) { do { let device = try store.add(value); dismiss(); onPaired(device) } catch { self.error = error.localizedDescription } }
}

private struct CodexHostView: View {
    @EnvironmentObject private var navigation: AppNavigation
    @StateObject private var service: CodexConnectService
    @Environment(\.scenePhase) private var scenePhase
    @State private var projects: [CodexRow] = []
    @State private var projectsExpanded = false
    @State private var threads: [CodexRow] = []
    @State private var cursor: String?
    @State private var loading = false
    @State private var creating = false
    @State private var created: CodexRow?
    init(device: CodexDevice) { _service = StateObject(wrappedValue: CodexConnectService.session(for: device)) }
    var body: some View {
        List {
            Section {
                Label(service.status, systemImage: service.connected ? "checkmark.circle.fill" : "wifi.slash").foregroundStyle(service.connected ? .green : .secondary)
                Text("电脑本机记录 · 服务器仅转发").font(.caption).foregroundStyle(.secondary)
                CodexQuotaButton(service: service)
                if let error = service.error { Text(error).font(.footnote).foregroundStyle(.red) }
                if !service.connected { Button("重新连接") { Task { await load() } }.disabled(loading) }
            }
            CodexActivitySection(device: service.device)
            Group {
                Section {
                    DisclosureGroup(isExpanded: $projectsExpanded) {
                    ForEach(projects) { project in NavigationLink { CodexThreadsView(service: service, project: project) } label: { Label(project.title, systemImage: "folder") }.disabled(!service.connected) }
                    if projects.isEmpty && service.connected { Text("本机 Codex 暂无项目").foregroundStyle(.secondary) }
                    } label: {
                        HStack { Label("本机项目", systemImage: "folder"); Spacer(); Text("\(projects.count)").foregroundStyle(.secondary) }
                    }
                }
            }
            Group {
                Section("最近对话") {
                    ForEach(threads) { thread in
                        NavigationLink { CodexChatView(service: service, thread: thread) } label: { VStack(alignment: .leading, spacing: 4) { Text(service.title(for: thread)).lineLimit(2); Text(thread.path).font(.caption).foregroundStyle(.secondary) } }
                            .disabled(!service.connected)
                            .modifier(CodexDeleteChat(service: service, thread: thread, onDeleted: { await load() }))
                    }
                    if cursor != nil { Button("查看更多（20 条）") { Task { await load(more: true) } }.disabled(loading) }
                    if threads.isEmpty && service.connected && !loading { Text("本机暂无对话").foregroundStyle(.secondary) }
                }
            }
            if loading { ProgressView() }
        }
        .navigationTitle(service.device.displayName).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("连接设备", systemImage: "desktopcomputer") { navigation.tab = .connections } }
            ToolbarItem(placement: .topBarTrailing) { Button("新建对话", systemImage: "square.and.pencil") { creating = true }.disabled(!service.connected) }
        }
        .sheet(isPresented: $creating) { CodexNewChatView(service: service, projects: projects) { row in created = row; Task { await load() } } }
        .navigationDestination(item: $created) { row in CodexChatView(service: service, thread: row) }
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await service.resumeConnection() } } }
        .onChange(of: service.connected) { _, connected in if connected && projects.isEmpty && threads.isEmpty && !loading { Task { await load() } } }
    }
    private func load(more: Bool = false) async {
        guard !loading else { return }; loading = true; defer { loading = false }
        if !service.connected { await service.connect() }
        guard service.connected else { return }
        do {
            if !more {
                let r = try await service.request("projects")
                projects = (r["projects"] as? [[String: Any]] ?? []).compactMap { x in guard let id = x["id"] as? String, let name = x["name"] as? String else { return nil }; return CodexRow(id: id, title: name) }
            }
            do {
                var params: [String: Any] = ["limit": 20]; if more, let cursor { params["cursor"] = cursor }
                let r = try await service.request("threads", params)
                let rows = (r["threads"] as? [[String: Any]] ?? []).compactMap { x -> CodexRow? in guard let id = x["id"] as? String, let title = x["title"] as? String else { return nil }; return CodexRow(id: id, title: title, path: x["projectName"] as? String ?? "未分组") }
                if more { for row in rows where !threads.contains(where: { $0.id == row.id }) { threads.append(row) } } else { threads = rows }
                cursor = r["nextCursor"] as? String
            }
        } catch { service.error = error.localizedDescription }
    }
}

private struct CodexThreadsView: View {
    @ObservedObject var service: CodexConnectService
    let project: CodexRow
    @State private var threads: [CodexRow] = []
    @State private var cursor: String?
    @State private var loading = false
    @State private var creating = false
    @State private var created: CodexRow?
    var body: some View {
        List {
            Section { NavigationLink { CodexFilesView(service: service, project: project, path: "", title: "项目文件") } label: { Label("项目文件与下载", systemImage: "arrow.down.doc") } }
            Section("对话") {
                ForEach(threads) { thread in
                    NavigationLink { CodexChatView(service: service, thread: thread) } label: { Text(service.title(for: thread)).lineLimit(2) }
                        .modifier(CodexDeleteChat(service: service, thread: thread, onDeleted: { await load() }))
                }
                if let _ = cursor { Button("查看更多（20 条）") { Task { await load(more: true) } }.disabled(loading) }
                if loading { ProgressView() }
                if threads.isEmpty && !loading { Text("此项目还没有对话，点击右上角新建。").foregroundStyle(.secondary) }
            }
            if let error = service.error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .navigationTitle(project.title).task { await load() }.refreshable { await load() }
        .toolbar { Button("新建对话", systemImage: "square.and.pencil") { creating = true }.disabled(!service.connected) }
        .sheet(isPresented: $creating) { CodexNewChatView(service: service, projects: [project], initialProjectID: project.id) { row in created = row; Task { await load() } } }
        .navigationDestination(item: $created) { row in CodexChatView(service: service, thread: row) }
    }
    private func load(more: Bool = false) async {
        guard !loading else { return }; loading = true; defer { loading = false }
        if !service.connected { await service.connect() }
        do {
            var p: [String: Any] = ["projectId": project.id, "limit": 20]; if more, let cursor { p["cursor"] = cursor }
            let r = try await service.request("threads", p)
            let rows = (r["threads"] as? [[String: Any]] ?? []).compactMap { x -> CodexRow? in guard let id = x["id"] as? String, let title = x["title"] as? String else { return nil }; return CodexRow(id: id, title: title) }
            if more { for row in rows where !threads.contains(where: { $0.id == row.id }) { threads.append(row) } } else { threads = rows }
            cursor = r["nextCursor"] as? String
        } catch { service.error = error.localizedDescription }
    }
}

struct CodexNewChatView: View {
    @ObservedObject var service: CodexConnectService
    let projects: [CodexRow]
    var initialProjectID: String = ""
    let onCreated: (CodexRow) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var projectID = ""
    @State private var busy = false
    @State private var attempted = false
    @State private var requestID = UUID().uuidString
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("对话名称（可选）", text: $title).disabled(attempted)
                    Picker("所属项目", selection: $projectID) {
                        Text("无项目").tag("")
                        ForEach(projects) { Text($0.title).tag($0.id) }
                    }.disabled(attempted)
                }
                Section { Text(projectID.isEmpty ? "在电脑建立独立工作目录，对话会显示在最近列表。" : "使用电脑项目的工作目录，对话同步到该项目。").font(.footnote).foregroundStyle(.secondary) }
                if busy { ProgressView("正在电脑上创建…") }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("新建对话").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button(attempted ? "重试" : "创建") { Task { await create() } }.disabled(busy || !service.connected) }
            }
            .interactiveDismissDisabled(busy)
            .onAppear { if !attempted { projectID = initialProjectID } }
        }
    }
    private func create() async {
        busy = true; attempted = true; error = nil; defer { busy = false }
        do {
            let result = try await service.request("createThread", ["requestId": requestID, "title": title, "projectId": projectID])
            guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else { throw CodexConnectError(message: "电脑未返回对话，请刷新列表查看。") }
            dismiss(); onCreated(CodexRow(id: id, title: thread["title"] as? String ?? "新对话"))
        } catch { self.error = error.localizedDescription }
    }
}

struct CodexDeleteChat: ViewModifier {
    @ObservedObject var service: CodexConnectService
    let thread: CodexRow
    let onDeleted: () async -> Void
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirming = false
    @State private var deleting = false
    @State private var requestID = UUID().uuidString
    func body(content: Content) -> some View {
        content
            .swipeActions {
                Button("删除", role: .destructive) { confirming = true }.disabled(deleting || !service.connected)
                Button("重命名", systemImage: "pencil") { newTitle = service.title(for: thread); renaming = true }.tint(.blue).disabled(deleting || !service.connected)
            }
            .contextMenu {
                Button("重命名", systemImage: "pencil") { newTitle = service.title(for: thread); renaming = true }.disabled(deleting || !service.connected)
                Button("删除对话", systemImage: "trash", role: .destructive) { confirming = true }.disabled(deleting || !service.connected)
            }
            .alert("重命名对话", isPresented: $renaming) {
                TextField("对话名称", text: $newTitle)
                Button("取消", role: .cancel) { }
                Button("保存") { Task {
                    deleting = true; defer { deleting = false }
                    do { try await service.renameThread(thread.id, title: newTitle.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    catch { service.error = error.localizedDescription }
                } }.disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newTitle.count > 120)
            }
            .overlay(alignment: .trailing) { if deleting { ProgressView() } }
            .alert("永久删除对话？", isPresented: $confirming) {
                Button("取消", role: .cancel) { }
                Button("删除", role: .destructive) { Task {
                    deleting = true; defer { deleting = false }
                    do {
                        _ = try await service.request("deleteThread", ["threadId": thread.id, "confirm": true, "requestId": requestID])
                        await onDeleted()
                    } catch { service.error = error.localizedDescription }
                } }
            } message: { Text("“\(thread.title)”将从电脑和手机中删除，无法恢复；项目文件不会被删除。") }
    }
}

struct CodexChatView: View {
    @ObservedObject var service: CodexConnectService
    @State var thread: CodexRow
    @EnvironmentObject private var navigation: AppNavigation
    var body: some View {
        CodexChatContent(service: service, thread: thread, selectThread: { thread = $0 }, returnToDevice: { navigation.tab = .connections }).id(thread.id)
    }
}

private struct CodexChatContent: View {
    @ObservedObject var service: CodexConnectService
    let thread: CodexRow
    let selectThread: (CodexRow) -> Void
    let returnToDevice: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var composerFocused: Bool
    @StateObject private var voice = CodexVoiceRecorder()
    @State private var voiceMode = false
    @AppStorage("codex.voice.preferLocal.v1") private var preferLocalVoice = true
    @State private var navigationOpen = false
    @State private var modelsOpen = false
    @State private var preview: CodexPreviewFile?
    @State private var previewTemporary: URL?
    @State private var previewLoading = false
    @State private var forkMessage: CodexChatMessage?
    @State private var forking = false
    @State private var bottomDistance: CGFloat = 0
    @State private var viewportHeight: CGFloat = 600
    @State private var initialScroll = false
    @State private var followOutput = true
    @State private var bottomScrollTask: Task<Void, Never>?
    @State private var draft = ""
    @State private var sending = false
    @State private var pendingID: String?
    @State private var pendingText: String?
    @State private var uncertain = false
    @State private var browsingOlder = false
    @State private var importing = false
    @State private var choosingPhoto = false
    @State private var loadingPhoto = false
    @State private var photo: PhotosPickerItem?
    @State private var attachments: [URL] = []
    @State private var uploadedIDs: [String] = []
    @State private var pendingDownload: String?
    @Environment(\.openURL) private var openURL
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(service.running ? (service.progressLabel.isEmpty ? "Codex 正在处理…" : service.progressLabel) : service.status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { modelsOpen = true } label: {
                        HStack(spacing: 3) { Text(service.models.first(where: { $0.id == service.currentModel })?.title ?? (service.currentModel.isEmpty ? "模型" : service.currentModel)).lineLimit(1); Image(systemName: "chevron.down") }.font(.caption)
                    }.disabled(!service.writable)
                }
                if service.approvalNeeded { Label("有操作等待确认，请在电脑处理后继续。", systemImage: "hand.raised").font(.footnote).foregroundStyle(.orange) }
                CodexQuotaButton(service: service)
                if let error = service.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if let failure = service.taskFailure { Text(failure).font(.caption).foregroundStyle(.red).lineLimit(4).textSelection(.enabled) }
                if !service.writable {
                    Button("在电脑打开此对话") { Task { do { _ = try await service.request("activate", ["threadId": thread.id]); try? await Task.sleep(for: .seconds(2)); await service.select(thread.id) } catch { service.error = error.localizedDescription } } }
                        .font(.footnote).disabled(!service.connected)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.vertical, 8)
            GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    // History is bounded. Measure its actual height so sending / keyboard
                    // resizing cannot scroll beyond a lazy stack's estimated bottom.
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            if service.olderCursor != nil { Button("上一页记录") { Task { browsingOlder = true; await service.older(thread.id) } } }
                            Spacer()
                            if browsingOlder { Text("正在查看较早记录").foregroundStyle(.secondary) }
                        }.font(.caption)
                        ForEach(CodexChatTimeline.groups(service.messages)) { group in
                            CodexChatGroupView(service: service, threadID: thread.id, group: group, forking: forking, openFile: openPCFile, fork: { forkMessage = $0 })
                        }
                        if !browsingOlder {
                            ForEach(service.questions) { group in CodexQuestionCard(group: group, service: service, threadID: thread.id) }
                            if service.running {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack { ProgressView(); Text(service.progressLabel.isEmpty ? "正在处理…" : service.progressLabel).font(.subheadline) }

                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding()
                    .background(GeometryReader { content in Color.clear.preference(key: CodexChatBottomKey.self, value: content.frame(in: .named("codex-chat-scroll")).maxY) })
                }
                .defaultScrollAnchor(.bottom)
                .coordinateSpace(name: "codex-chat-scroll")
                .onAppear { viewportHeight = viewport.size.height }
                .onChange(of: viewport.size.height) { _, height in viewportHeight = height; scrollToLatest(proxy) }
                .onPreferenceChange(CodexChatBottomKey.self) { bottom in bottomDistance = max(0, bottom - viewport.size.height); followOutput = bottomDistance < 140 }
                .onChange(of: service.messages.last?.text) { _, _ in
                    scrollToLatest(proxy)
                }
                .onChange(of: service.messages.last?.id) { _, _ in scrollToLatest(proxy) }
                .onChange(of: sending) { _, _ in scrollToLatest(proxy) }
                .overlay(alignment: .bottomTrailing) {
                    if bottomDistance > max(600, viewportHeight * 1.25) || browsingOlder {
                        Button { Task {
                            if browsingOlder { browsingOlder = false; await service.select(thread.id) }
                            followOutput = true
                            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                        } } label: { Image(systemName: "arrow.down").font(.headline).padding(14).background(.regularMaterial, in: Circle()).shadow(radius: 3) }.padding(16).accessibilityLabel("回到底部")
                    }
                }
            }
            }
            if uncertain { Text("送达状态待核实。先点“回到最新”查看；重试将沿用原消息 ID，避免重复提交。").font(.caption).foregroundStyle(.orange).padding(.horizontal) }
            CodexQueuedCards(service: service, threadID: thread.id).padding(.horizontal)
            CodexDownloadCard(service: service).padding(.horizontal)
            if let notice = (service.running ? nil : service.notice) { Text(notice).font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
            if loadingPhoto { ProgressView("正在读取照片…").padding(.horizontal) }
            if previewLoading { ProgressView("正在读取预览…").padding(.horizontal) }
            if forking { ProgressView("正在创建分支…").padding(.horizontal) }
            if let progress = service.uploadProgress { ProgressView("上传附件", value: progress).padding(.horizontal) }
            if !attachments.isEmpty {
                ScrollView(.horizontal) { HStack { ForEach(attachments, id: \.self) { url in
                    HStack(spacing: 8) {
                        Button { preview = CodexPreviewFile(url: url) } label: { Label(url.lastPathComponent, systemImage: "paperclip").font(.caption).lineLimit(1) }.accessibilityLabel("预览 " + url.lastPathComponent)
                        Button { attachments.removeAll { $0 == url }; try? FileManager.default.removeItem(at: url) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("移除附件").disabled(sending || uncertain)
                    }.padding(8).background(.secondary.opacity(0.12), in: Capsule())
                } }.padding(.horizontal) }
            }
            if voiceMode || voice.error != nil { CodexVoicePreview(voice: voice, preferLocal: $preferLocalVoice) }
            CodexComposerShell {
                Button {
                    voice.cancel()
                    voiceMode.toggle()
                    composerFocused = !voiceMode
                } label: { Image(systemName: voiceMode ? "keyboard" : "waveform") }
                    .buttonStyle(CodexComposerButtonStyle())
                    .accessibilityLabel(voiceMode ? "切换键盘输入" : "切换按住说话")
                    .disabled(sending || uncertain)
                if voiceMode {
                    CodexHoldToTalk(voice: voice, service: service, preferLocal: preferLocalVoice,
                                    disabled: sending || uncertain || (!preferLocalVoice && !service.connected)) { value in
                        draft += (draft.isEmpty || draft.hasSuffix("\n") ? "" : "\n") + value
                        voiceMode = false
                        composerFocused = true
                    }
                } else {
                    TextField("", text: $draft, prompt: Text("发消息…").foregroundColor(Color(uiColor: .secondaryLabel)), axis: .vertical)
                        .font(.system(size: 17)).lineLimit(1...5).textFieldStyle(.plain)
                        .frame(minHeight: 44).padding(.horizontal, 6)
                        .focused($composerFocused).disabled(sending || uncertain)
                }
                Menu {
                    Button("选择文件", systemImage: "doc") { importing = true }
                    Button("选择照片", systemImage: "photo") { choosingPhoto = true }
                } label: { Image(systemName: "plus").font(.system(size: 21, weight: .regular)).foregroundStyle(.secondary).frame(width: 44, height: 44) }
                    .buttonStyle(.plain).accessibilityLabel("添加照片或文件")
                    .disabled(sending || uncertain || loadingPhoto || attachments.count >= 6 || voice.active)
                if service.running { Button { Task { await service.stop(thread.id) } } label: { Image(systemName: "stop.fill").font(.system(size: 15)) }.buttonStyle(CodexComposerButtonStyle()).accessibilityLabel("停止") }
                if !voiceMode {
                    Button { Task { await send() } } label: { if sending { ProgressView() } else { Image(systemName: uncertain ? "arrow.clockwise" : "arrow.up") } }
                        .buttonStyle(CodexComposerButtonStyle(primary: true)).accessibilityLabel(uncertain ? "重试发送" : "发送消息")
                        .disabled(sending || loadingPhoto || !service.connected || !service.writable || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty && uploadedIDs.isEmpty) || browsingOlder)
                }
            }
            if uncertain { Button("已核实，清除输入") { if let id = pendingID { service.dismissOutgoing(id) }; clearPending(); service.error = nil }.font(.caption).padding(.bottom, 6) }
        }
        .accessibilityHidden(navigationOpen)
        .overlay { chatNavigationOverlay }
        .navigationTitle(service.title(for: thread)).navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { setNavigationOpen(!navigationOpen) } label: {
                    Image(systemName: "line.3.horizontal").overlay(alignment: .topTrailing) {
                        if !service.activeTasks.isEmpty { Text(String(service.activeTasks.count)).font(.system(size: 10, weight: .bold)).foregroundStyle(.white).padding(4).background(.green, in: Circle()).offset(x: 10, y: -9) }
                    }
                }.accessibilityLabel(navigationOpen ? "关闭对话导航" : "对话导航，\(service.activeTasks.count) 个任务正在运行")
            }
            ToolbarItem(placement: .topBarTrailing) { NavigationLink { CodexFilesView(service: service, project: CodexRow(id: "thread:" + thread.id, title: "对话文件"), path: "", title: "对话文件") } label: { Image(systemName: "folder") }.disabled(navigationOpen) }
        }
        .sheet(isPresented: $modelsOpen) { CodexModelPicker(service: service, threadID: thread.id) }
        .modifier(CodexChatPreviewModifier(preview: $preview, onDismiss: cleanPreview))
        .alert("创建对话分支？", isPresented: Binding(get: { forkMessage != nil }, set: { if !$0 { forkMessage = nil } })) {
            Button("取消", role: .cancel) { forkMessage = nil }
            Button("创建分支") { if let message = forkMessage { Task { await fork(message) } }; forkMessage = nil }
        } message: { Text("复制到所选回复所在轮次结束的记录，进入新对话继续。原对话保持不变；正在输出的轮次需先完成。") }
        .task {
            if let saved = KeychainStore.get(account: pendingAccount), let data = saved.data(using: .utf8),
               let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = value["id"] as? String, let text = value["text"] as? String {
                pendingID = id; pendingText = text; draft = text; uncertain = true; uploadedIDs = value["attachments"] as? [String] ?? []
            }
            if let savedDraft = UserDefaults.standard.string(forKey: draftAccount), !uncertain { draft = savedDraft }
            if service.selectedThread != thread.id { await service.select(thread.id) }
            if service.writable { await service.refreshModels(thread.id) }
            while !Task.isCancelled {
                if scenePhase == .active {
                    await service.refreshActivity()
                    if bottomDistance < 140 && !browsingOlder && !navigationOpen && !modelsOpen && preview == nil { await service.markRead(thread.id) }
                }
                try? await Task.sleep(for: .seconds(4))
            }
        }
        .onDisappear {
            bottomScrollTask?.cancel()
            voice.cancel(); UserDefaults.standard.set(draft, forKey: draftAccount)
            // Opening the image modal must not clear the underlying chat or detach its stream.
            if preview == nil { service.leaveChat(thread.id) }
        }
        .onChange(of: thread.id) { _, _ in voice.cancel(); voiceMode = false }
        .onChange(of: scenePhase) { _, phase in if phase != .active && (voice.recording || voice.finishing) { voice.cancel() } }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in voice.cancel() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            do { for url in try result.get() { try addFile(url) } } catch { service.error = error.localizedDescription }
        }
        .photosPicker(isPresented: $choosingPhoto, selection: $photo, matching: .images, preferredItemEncoding: .current)
        .onChange(of: photo) { _, item in Task { await addPhoto(item) } }
        .alert("下载电脑文件？", isPresented: Binding(get: { pendingDownload != nil }, set: { if !$0 { pendingDownload = nil } })) {
            Button("下载") { if let path = pendingDownload { Task { do { _ = try await service.download(projectID: "thread:" + thread.id, path: path, absolute: true) } catch is CancellationError { } catch { service.error = error.localizedDescription } } }; pendingDownload = nil }
            Button("取消", role: .cancel) { pendingDownload = nil }
        } message: { Text(pendingDownload ?? "") }
    }
    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard !browsingOlder, preview == nil, followOutput || !initialScroll else { return }
        initialScroll = true
        bottomScrollTask?.cancel()
        bottomScrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }
    private var chatNavigationOverlay: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                if navigationOpen {
                    Button { setNavigationOpen(false) } label: {
                        Color.black.opacity(0.28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭对话导航")
                    .transition(.opacity)

                    CodexChatNavigation(
                        service: service,
                        currentID: thread.id,
                        select: { row in
                            setNavigationOpen(false)
                            if row.id != thread.id { selectThread(row) }
                        },
                        exit: {
                            setNavigationOpen(false)
                            returnToDevice()
                        }
                    )
                    .frame(width: min(300, geometry.size.width * 0.74))
                    .frame(maxHeight: .infinity)
                    .background(Color(uiColor: .systemGroupedBackground))
                    .shadow(color: .black.opacity(0.16), radius: 12, x: 4)
                    .transition(.move(edge: .leading))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .clipped()
        }
        .allowsHitTesting(navigationOpen)
    }

    private func setNavigationOpen(_ open: Bool) {
        if open { composerFocused = false }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            navigationOpen = open
        }
    }

    private var draftAccount: String { "codex.draft." + service.device.id + "." + thread.id }
    private func cleanPreview() {
        if let file = previewTemporary { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()); previewTemporary = nil }
    }
    private func openPCFile(_ path: String) {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "heic", "gif", "webp", "pdf"].contains(ext) {
            guard !previewLoading else { return }; previewLoading = true
            Task { defer { previewLoading = false }; do {
                let file = try await service.download(projectID: "thread:" + thread.id, path: path, absolute: true, preview: true)
                previewTemporary = file; preview = CodexPreviewFile(url: file)
            } catch { service.error = error.localizedDescription } }
        } else { pendingDownload = path }
    }
    private func fork(_ message: CodexChatMessage) async {
        guard let turnID = message.turnID, !forking else { return }
        forking = true; defer { forking = false }
        do {
            let key = "codex.fork." + service.device.id + "." + thread.id + "." + message.id
            let requestID = UserDefaults.standard.string(forKey: key) ?? UUID().uuidString
            UserDefaults.standard.set(requestID, forKey: key)
            let result = try await service.request("forkThread", ["threadId": thread.id, "turnId": turnID, "requestId": requestID])
            guard let row = result["thread"] as? [String: Any], let id = row["id"] as? String else { throw CodexConnectError(message: "未收到分支记录，请刷新对话列表") }
            UserDefaults.standard.removeObject(forKey: key)
            selectThread(CodexRow(id: id, title: row["title"] as? String ?? "分支"))
        } catch { service.error = error.localizedDescription }
    }
    private var pendingAccount: String { "codex.pending." + service.device.id + "." + thread.id }
    private func clearPending() {
        KeychainStore.delete(account: pendingAccount); draft = ""; pendingID = nil; pendingText = nil; uncertain = false; uploadedIDs = []
        for url in attachments { try? FileManager.default.removeItem(at: url) }; attachments = []
    }
    private func persistPending() throws {
        let data = try JSONSerialization.data(withJSONObject: ["id": pendingID!, "text": pendingText ?? draft, "attachments": uploadedIDs])
        try KeychainStore.set(String(decoding: data, as: UTF8.self), account: pendingAccount)
    }
    private func send() async {
        sending = true; service.notice = nil; followOutput = true; defer { sending = false }
        if pendingID == nil { pendingID = UUID().uuidString; pendingText = draft }
        let id = pendingID!
        if !service.running { service.showOutgoing(pendingText ?? draft, to: thread.id, messageID: id, names: attachments.map(\.lastPathComponent)) }
        var submitted = false
        do {
            if !uncertain { for url in attachments.dropFirst(uploadedIDs.count) { uploadedIDs.append(try await service.upload(url, threadID: thread.id)) } }
            try persistPending(); submitted = true
            try await service.send(pendingText ?? draft, to: thread.id, messageID: id, attachments: uploadedIDs)
            clearPending(); service.error = nil
        } catch {
            uncertain = submitted || uncertain
            service.updateDelivery(id, uncertain ? "送达待确认" : "上传失败，可重试")
            service.error = error.localizedDescription
            if !uncertain { service.dismissOutgoing(id); pendingID = nil; pendingText = nil; uploadedIDs = [] }
        }
    }
    private func addFile(_ url: URL) throws {
        guard attachments.count < 6 else { throw CodexConnectError(message: "每条消息最多 6 个附件") }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, (size.fileSize ?? Int.max) <= 25 * 1024 * 1024 else { throw CodexConnectError(message: "请选择不超过 25 MB 的文件") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-attachment-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent(url.lastPathComponent); try FileManager.default.copyItem(at: url, to: target); attachments.append(target)
    }
    private func addPhoto(_ item: PhotosPickerItem?) async {
        guard let item, !loadingPhoto else { return }
        loadingPhoto = true; service.error = nil
        defer { loadingPhoto = false; photo = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw CodexConnectError(message: "照片读取失败；若照片在 iCloud，请联网后重试") }
            guard data.count <= 50 * 1024 * 1024 else { throw CodexConnectError(message: "照片超过 50 MB，请选择较小的图片") }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
                  let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.85) else { throw CodexConnectError(message: "无法读取图片") }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("照片-" + String(UUID().uuidString.prefix(8)) + ".jpg")
            try jpeg.write(to: url); defer { try? FileManager.default.removeItem(at: url) }; try addFile(url)
        } catch { service.error = error.localizedDescription }
    }

}

private struct CodexFilesView: View {
    @ObservedObject var service: CodexConnectService
    let project: CodexRow
    let path: String
    let title: String
    @State private var files: [CodexRow] = []
    @State private var limited = false
    @State private var notice: String?
    @State private var downloading: Task<Void, Never>?
    var body: some View {
        List {
            if service.downloadState != nil { Section { CodexDownloadCard(service: service) } }
            if let notice { Text(notice).font(.footnote).textSelection(.enabled) }
            ForEach(files) { file in
                if file.directory { NavigationLink { CodexFilesView(service: service, project: project, path: file.path, title: file.title) } label: { Label(file.title, systemImage: "folder") } }
                else { Button { download(file) } label: { HStack { Label(file.title, systemImage: "arrow.down.doc"); Spacer(); Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)).font(.caption).foregroundStyle(.secondary) } }.disabled(service.downloadProgress != nil) }
            }
            if limited { Text("此目录仅显示前 200 项，请在电脑整理子目录后查看。").font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle(title).task { await load() }.refreshable { await load() }
    }
    private func load() async {
        do { let r = try await service.request("files", ["projectId": project.id, "relativePath": path]); limited = r["limited"] as? Bool ?? false
            files = (r["files"] as? [[String: Any]] ?? []).compactMap { x in guard let name = x["name"] as? String, let path = x["relativePath"] as? String else { return nil }; return CodexRow(id: path, title: name, path: path, directory: x["isDirectory"] as? Bool ?? false, size: x["size"] as? Int ?? 0) }.sorted { $0.directory != $1.directory ? $0.directory : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        } catch { notice = error.localizedDescription }
    }
    private func download(_ file: CodexRow) { downloading = Task { do { _ = try await service.download(projectID: project.id, path: file.path); notice = nil } catch is CancellationError { notice = "下载已取消" } catch { notice = error.localizedDescription } } }
}

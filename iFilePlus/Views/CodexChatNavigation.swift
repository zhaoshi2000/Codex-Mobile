import SwiftUI

struct CodexQuotaButton: View {
    @ObservedObject var service: CodexConnectService
    @State private var showing = false
    var body: some View {
        Button {
            showing = true
            Task { await service.refreshQuota(force: true) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                if let first = service.quota.first {
                    Text("\(first.label)剩余 \(first.remaining, specifier: "%.0f")%")
                } else { Text(service.quotaLoading ? "正在读取 Codex 额度…" : "Codex 额度") }
                Image(systemName: "chevron.right")
            }.font(.caption)
        }
        .disabled(!service.connected)
        .task { await service.refreshQuota() }
        .onChange(of: service.connected) { _, connected in if connected { Task { await service.refreshQuota(force: true) } } }
        .sheet(isPresented: $showing) {
            NavigationStack {
                List {
                    Section("电脑当前登录的 Codex 账号") {
                        ForEach(service.quota) { window in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text(window.label); Spacer(); Text("剩余 \(window.remaining, specifier: "%.0f")%") }
                                ProgressView(value: window.remaining, total: 100)
                                if let reset = window.resetsAt { Text("重置时间：" + reset.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical, 4)
                        }
                        if service.quota.isEmpty { Text(service.quotaMessage).foregroundStyle(.secondary) }
                    }
                    if let checked = service.quotaCheckedAt { Text("查询时间：" + checked.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                    Button("刷新额度") { Task { await service.refreshQuota(force: true) } }.disabled(service.quotaLoading || !service.connected)
                    if service.quotaLoading { ProgressView() }
                }.navigationTitle("Codex 剩余额度").navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("完成") { showing = false } }
            }
        }
    }
}
import QuickLook
import ImageIO

struct CodexDownloadCard: View {
    @ObservedObject var service: CodexConnectService
    var body: some View {
        if let state = service.downloadState, !state.preview {
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
                    Text("已保存到：服务 → 文件管理器 → Codex 下载").font(.caption).foregroundStyle(.secondary)
                    ShareLink(item: file) { Label("分享 / 导出", systemImage: "square.and.arrow.up") }
                        .font(.subheadline)
                } else if let error = state.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }.padding(12).background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .contain)
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
            Label((item.toolStatus == "inProgress" ? "正在运行 " : "") + item.text, systemImage: "terminal").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
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
            Label((items.last?.toolStatus == "inProgress" ? "正在运行 " : "") + (items.last?.text ?? "运行了命令"), systemImage: "terminal").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
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
    @State private var showingUsage = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(group.blocks) { block in
                if block.isCommands { CodexCommandGroup(service: service, threadID: threadID, items: block.items) }
                else if let message = block.items.first {
                    let images = CodexMessageImages(message.role == "user" ? message.text : "")
                    if !images.paths.isEmpty {
                        HStack { Spacer(minLength: 0); CodexImageStack(service: service, threadID: threadID, paths: images.paths, open: openFile) }
                    }
                    if message.role != "user" || !images.body.isEmpty {
                    HStack {
                        if group.isUser { Spacer(minLength: 24) }
                        CodexMarkdownView(text: message.role == "user" ? images.body : message.text).textSelection(.enabled)
                        .foregroundStyle(message.role == "error" ? Color.red : Color.primary)
                        .padding(group.isUser ? 12 : 0)
                        .background(group.isUser ? Color.blue.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                        .environment(\.openURL, OpenURLAction { url in
                            if url.scheme == "ifilepc", let data = Data(codexBase64URL: url.lastPathComponent), let path = String(data: data, encoding: .utf8) { openFile(path); return .handled }
                            if ["https", "http", "mailto"].contains(url.scheme ?? "") { return .systemAction }
                            return .discarded
                        })
                    }
                    }
                    if let delivery = message.delivery { Text(delivery).font(.caption).foregroundStyle(.secondary) }
                    if message.truncated { Text("长消息已截取，请在电脑查看完整内容。").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let reply = group.reply {
                HStack(spacing: 4) {
                    Button { UIPasteboard.general.string = group.text; copied = true } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc").frame(width: 36, height: 40) }.accessibilityLabel("复制本轮回复")
                    ShareLink(item: group.text) { Image(systemName: "square.and.arrow.up").frame(width: 36, height: 40) }.accessibilityLabel("分享本轮回复")
                    if reply.turnID != nil { Button { fork(reply) } label: { Image(systemName: "arrow.triangle.branch").frame(width: 36, height: 40) }.accessibilityLabel("创建分支").disabled(forking || !service.connected) }
                    Button { showingUsage = true } label: {
                        Label(reply.tokenCount.map { "用量 " + $0.formatted(.number.notation(.compactName)) + " tok" } ?? "用量 —", systemImage: "cylinder")
                            .font(.system(size: 11)).lineLimit(1).padding(.horizontal, 4).frame(minHeight: 40)
                    }.accessibilityLabel("查看本轮用量")
                    if let completedAt = reply.completedAt, completedAt > 0 {
                        Text(Date(timeIntervalSince1970: completedAt / 1000), format: .dateTime.hour().minute())
                            .font(.system(size: 11)).monospacedDigit().padding(.leading, 4).accessibilityLabel("输出完成时间")
                    }
                }.font(.system(size: 13)).buttonStyle(.plain).foregroundStyle(.secondary).padding(.top, 2)
                    .alert("本轮用量", isPresented: $showingUsage) {
                        Button("知道了", role: .cancel) { }
                    } message: {
                        Text(reply.tokenCount.map { "电脑记录的本轮用量：\($0) tokens。" } ?? "电脑尚未提供这轮回复的 token 用量。这里不使用字数估算，也不把整段对话累计用量当作本轮用量。")
                    }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CodexChatScrollInteraction: ViewModifier {
    let changed: (Bool) -> Void
    let measured: (CGFloat) -> Void
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, geometry.contentSize.height - geometry.visibleRect.maxY)
            } action: { _, distance in measured(distance) }
            .onScrollPhaseChange { old, new, context in
                let wasUser = old == .tracking || old == .interacting || old == .decelerating
                let isUser = new == .tracking || new == .interacting || new == .decelerating
                if isUser { changed(true) }
                if wasUser || isUser {
                    measured(max(0, context.geometry.contentSize.height - context.geometry.visibleRect.maxY))
                    if !isUser { changed(false) }
                }
            }
        } else {
            content.simultaneousGesture(DragGesture(minimumDistance: 8)
                .onChanged { _ in changed(true) }.onEnded { _ in changed(false) })
        }
    }
}

struct CodexChatBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
struct CodexPreviewFile: Identifiable {
    let url: URL
    var id: String { url.path }
    var isImage: Bool { ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "tiff"].contains(url.pathExtension.lowercased()) }
}

struct CodexChatPreviewModifier: ViewModifier {
    @Binding var preview: CodexPreviewFile?
    let onDismiss: () -> Void
    private var document: Binding<CodexPreviewFile?> { Binding(get: { preview?.isImage == false ? preview : nil }, set: { preview = $0 }) }
    private var photo: Binding<CodexPreviewFile?> { Binding(get: { preview?.isImage == true ? preview : nil }, set: { preview = $0 }) }
    func body(content: Content) -> some View {
        content.sheet(item: document, onDismiss: onDismiss) { file in
            NavigationStack {
                CodexFilePreview(url: file.url).ignoresSafeArea(edges: .bottom)
                    .navigationTitle(file.url.lastPathComponent).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { preview = nil } } }
            }
        }
        .fullScreenCover(item: photo, onDismiss: onDismiss) { file in
            CodexImagePreview(url: file.url, close: { preview = nil }).presentationBackground(.clear)
        }
    }
}

// A deliberately weak blur: system material alone obscures the entire chat.
struct CodexLightBlur: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: nil)
        view.isUserInteractionEnabled = false
        let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) { view.effect = UIBlurEffect(style: .regular) }
        animator.fractionComplete = 0.12
        context.coordinator.animator = animator
        return view
    }
    func updateUIView(_ view: UIVisualEffectView, context: Context) { }
    static func dismantleUIView(_ view: UIVisualEffectView, coordinator: Coordinator) { coordinator.animator?.stopAnimation(true) }
    final class Coordinator { var animator: UIViewPropertyAnimator? }
}

struct CodexComposerShell<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) { content }
            .padding(6)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26))
            .overlay { RoundedRectangle(cornerRadius: 26).strokeBorder(.primary.opacity(0.07), lineWidth: 0.5) }
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 10)
    }
}

struct CodexComposerButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 19, weight: .semibold))
            .frame(width: 44, height: 44)
            .foregroundStyle(primary && enabled ? Color.white : Color.primary.opacity(enabled ? 0.7 : 0.25))
            .background {
                if primary { Circle().fill(enabled ? Color.accentColor : Color.primary.opacity(0.08)).padding(3) }
            }
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

struct CodexImagePreview: View {
    let url: URL
    let close: () -> Void
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width * 0.82, 560)
            let height = min(geometry.size.height * 0.62, 620)
            ZStack {
                CodexLightBlur().ignoresSafeArea().allowsHitTesting(false)
                Color.black.opacity(0.10).ignoresSafeArea().contentShape(Rectangle()).onTapGesture(perform: close)
                VStack(spacing: 10) {
                    HStack {
                        Text(url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title2) }
                            .accessibilityLabel("关闭图片预览").frame(width: 44, height: 44)
                    }
                    if let image {
                        CodexZoomImage(image: image)
                            .frame(height: min(height, width * image.size.height / max(1, image.size.width)))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else if failed { Text("图片无法读取，请重新打开。").font(.callout).padding() }
                    else { ProgressView("正在读取图片…").frame(height: 100) }
                }
                .padding(12).frame(width: width + 24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
                .accessibilityAddTraits(.isModal)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: url) {
            let file = url
            let loaded = await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2400, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return Optional<UIImage>.none }
                return UIImage(cgImage: cg)
            }.value
            guard !Task.isCancelled else { return }
            image = loaded; failed = loaded == nil
        }
    }
}

struct CodexZoomImage: UIViewRepresentable {
    let image: UIImage
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView(); scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 5
        scroll.showsHorizontalScrollIndicator = false; scroll.showsVerticalScrollIndicator = false
        let view = context.coordinator.imageView; view.contentMode = .scaleAspectFit
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]; scroll.addSubview(view)
        return scroll
    }
    func updateUIView(_ scroll: UIScrollView, context: Context) {
        let view = context.coordinator.imageView
        if view.image !== image { scroll.setZoomScale(1, animated: false); view.image = image }
        if scroll.zoomScale == 1 { view.frame = scroll.bounds }
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    }
}
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
                    Text("推理强度：" + (service.currentEffort.isEmpty ? "模型默认（" + (service.modelDefaultEfforts[service.currentModel] ?? "自动") + "）" : service.currentEffort)).font(.caption).foregroundStyle(.secondary)
                    Text("使用电脑当前提供商的模型。任务运行期间切换，会用于后续轮次。").font(.footnote).foregroundStyle(.secondary)
                }
                if let efforts = service.modelEfforts[service.currentModel], !efforts.isEmpty {
                    Section("推理强度") {
                        ForEach(efforts, id: \.self) { effort in
                            Button { Task {
                                busy = true; error = nil; defer { busy = false }
                                do { try await service.chooseModel(service.currentModel, threadID: threadID, effort: effort) }
                                catch { self.error = error.localizedDescription }
                            } } label: {
                                HStack { Text(effortTitle(effort)); Spacer()
                                    if effort == (service.currentEffort.isEmpty ? service.modelDefaultEfforts[service.currentModel] : service.currentEffort) { Image(systemName: "checkmark") }
                                }
                            }.disabled(busy)
                        }
                    }
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
    private func effortTitle(_ value: String) -> String {
        let names = ["none": "不推理", "minimal": "最少", "low": "低", "medium": "中", "high": "高", "xhigh": "更高", "max": "最高", "ultra": "极高"]
        return names[value].map { $0 + " · " + value } ?? value
    }
}

struct CodexChatNavigation: View {
    @ObservedObject var service: CodexConnectService
    let currentID: String
    let select: (CodexRow) -> Void
    let exit: () -> Void
    @ObservedObject private var cache: CodexNavigationCache
    init(service: CodexConnectService, currentID: String, select: @escaping (CodexRow) -> Void, exit: @escaping () -> Void) {
        self.service = service; self.currentID = currentID; self.select = select; self.exit = exit
        self.cache = service.navigationCache
    }
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
                Section {
                    DisclosureGroup(isExpanded: $cache.projectsExpanded) {
                    ForEach(cache.projects) { project in
                        DisclosureGroup(isExpanded: Binding(get: { cache.expanded.contains(project.id) }, set: { open in
                            if open { cache.expanded.insert(project.id); Task { await cache.load(project.id) } }
                            else { cache.expanded.remove(project.id) }
                        })) {
                            ForEach(cache.page(project.id).rows) { thread in threadRow(thread) }
                            if cache.loading.contains(project.id) { ProgressView() }
                            if cache.page(project.id).cursor != nil { Button("查看更多（20 条）") { Task { await cache.load(project.id, more: true) } }.disabled(cache.loading.contains(project.id)) }
                            if cache.pages[project.id]?.rows.isEmpty == true { Text("暂无对话").foregroundStyle(.secondary) }
                        } label: {
                            HStack { Label(project.title, systemImage: "folder"); Spacer(); projectBadge(project.id) }
                        }
                    }
                    } label: {
                        HStack { Label("项目", systemImage: "folder"); Spacer(); Text("\(cache.projects.count)").foregroundStyle(.secondary) }
                    }
                }
                Section("最近对话") {
                    ForEach(cache.page().rows) { thread in threadRow(thread) }
                    if cache.page().cursor != nil { Button("查看更多（20 条）") { Task { await cache.load(more: true) } }.disabled(cache.loading.contains("")) }
                    if cache.loading.contains("") && cache.page().rows.isEmpty { ProgressView() }
                }
                if let error = cache.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .listStyle(.insetGrouped)
            .sheet(isPresented: $creating) { CodexNewChatView(service: service, projects: cache.projects) { row in select(row) } }
            .refreshable { await cache.refresh(force: true) }
            .task {
                // Let the opening animation finish; cached rows are visible immediately.
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await cache.refresh()
                while !Task.isCancelled { await service.refreshActivity(); try? await Task.sleep(for: .seconds(4)) }
            }
        }
    }
    private func threadRow(_ thread: CodexRow) -> some View {
        Button { select(thread) } label: {
            HStack(spacing: 10) {
                if thread.id == currentID { Image(systemName: "bubble.left.fill").font(.caption) }
                Text(service.title(for: thread)).foregroundStyle(.primary).lineLimit(2)
                Spacer(minLength: 4)
                if service.activeTasks.contains(where: { $0.id == thread.id }) { Circle().fill(.green).frame(width: 8, height: 8).accessibilityLabel("正在运行") }
                else if service.unreadThreads.contains(thread.id) { Circle().fill(.blue).frame(width: 8, height: 8).accessibilityLabel("完成未读") }
            }
        }
        .modifier(CodexDeleteChat(service: service, thread: thread, onDeleted: { await cache.refresh(force: true) }))
    }
    @ViewBuilder private func projectBadge(_ id: String) -> some View {
        if service.runningProjects.contains(id) { Circle().fill(.green).frame(width: 8, height: 8).accessibilityLabel("项目有任务正在运行") }
        else if service.unreadProjects.contains(id) { Circle().fill(.blue).frame(width: 8, height: 8).accessibilityLabel("项目有已完成未读任务") }
    }
}


struct CodexQueuedCards: View {
    @ObservedObject var service: CodexConnectService
    let threadID: String
    @State private var busy: String?
    var body: some View {
        if !service.queuedMessages.isEmpty {
            ScrollView(.vertical) {
                VStack(spacing: 6) {
                    ForEach(service.queuedMessages) { message in
                        HStack(spacing: 10) {
                            Image(systemName: "text.badge.clock").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(message.text).font(.subheadline).lineLimit(2)
                                Text(message.error ?? (message.preparing ? "正在加入队列…" : "等待当前任务完成"))
                                    .font(.caption2).foregroundStyle(message.error == nil ? Color.secondary : Color.orange)
                            }
                            Spacer(minLength: 0)
                            if message.editable {
                                Button("引导", systemImage: "arrow.turn.down.right") { change(message, steer: true) }.font(.caption).disabled(message.preparing)
                                Button { change(message, steer: false) } label: { Image(systemName: "trash") }.accessibilityLabel("移除等待消息")
                            }
                            if busy == message.id { ProgressView().controlSize(.small) }
                        }.padding(10).background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                            .disabled(busy != nil || !service.connected)
                    }
                }
            }.frame(height: CGFloat(min(service.queuedMessages.count, 2)) * 78)
        }
    }
    private func change(_ message: CodexQueuedMessage, steer: Bool) {
        busy = message.id
        Task { defer { busy = nil }; do { try await service.changeQueued(message.id, threadID: threadID, steer: steer) } catch { service.error = error.localizedDescription } }
    }
}

struct CodexImageStack: View {
    @ObservedObject var service: CodexConnectService
    let threadID: String
    let paths: [String]
    let open: (String) -> Void
    @State private var selected = 0
    private var index: Int { min(selected, max(0, paths.count - 1)) }
    private var visibleCount: Int { min(3, paths.count) }
    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .leading) {
                ForEach(Array((0..<visibleCount).reversed()), id: \.self) { offset in
                    let path = paths[(index + offset) % paths.count]
                    CodexImageThumbnail(service: service, threadID: threadID, path: path)
                            .frame(width: 112, height: 112).clipped()
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.background, lineWidth: 2))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 20).exclusively(before: TapGesture())
                                .onEnded { gesture in
                                    switch gesture {
                                    case .first(let drag):
                                        guard paths.count > 1, abs(drag.translation.width) > abs(drag.translation.height) * 1.3 else { return }
                                        withAnimation(.easeInOut(duration: 0.18)) { selected = (index + (drag.translation.width < 0 ? 1 : paths.count - 1)) % paths.count }
                                    case .second:
                                        if offset == 0 { open(path) } else { selected = (index + offset) % paths.count }
                                    }
                                }
                        )
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { if offset == 0 { open(path) } else { selected = (index + offset) % paths.count } }
                        .rotationEffect(.degrees(Double(offset * 5)))
                        .offset(x: CGFloat(offset * 18))
                        .zIndex(Double(3 - offset))
                        .accessibilityLabel(offset == 0 ? "查看图片 \(index + 1)，共 \(paths.count) 张" : "下一张图片")
                }
            }.frame(width: 112 + CGFloat(max(0, visibleCount - 1) * 18) + 12, height: 126, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityAdjustableAction { direction in
                    guard !paths.isEmpty else { return }
                    selected = (index + (direction == .increment ? 1 : paths.count - 1)) % paths.count
                }
            if paths.count > 1 { Text("\(index + 1) / \(paths.count)").font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

struct CodexImageThumbnail: View {
    @ObservedObject var service: CodexConnectService
    let threadID: String
    let path: String
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        ZStack {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else if failed { Image(systemName: "photo").foregroundStyle(.secondary) }
            else { ProgressView().controlSize(.small) }
        }.task(id: path + String(service.connected)) {
            image = service.cachedThumbnail(path, threadID: threadID); failed = false
            if image != nil { return }
            do {
                let loaded = try await service.imageThumbnail(path, threadID: threadID)
                if !Task.isCancelled { image = loaded }
            }
            catch { if !Task.isCancelled { failed = true } }
        }
    }
}

import SwiftUI

struct DualPaneView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var leftDirectory = LocalFileService.documentsDirectory
    @State private var rightDirectory = LocalFileService.documentsDirectory
    @State private var leftItems: [LocalFileItem] = []
    @State private var rightItems: [LocalFileItem] = []
    @State private var selectedLeft: LocalFileItem?
    @State private var selectedRight: LocalFileItem?
    @State private var activePane = 0
    @State private var editorDocument: EditorDocument?
    @State private var errorMessage: String?

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if geometry.size.width < 700 {
                    Picker("窗口", selection: $activePane) {
                        Text("左窗口").tag(0)
                        Text("右窗口").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    pane(side: activePane)
                } else {
                    HStack(spacing: 0) {
                        pane(side: 0)
                        Divider()
                        pane(side: 1)
                    }
                }

                Divider()
                HStack(spacing: 10) {
                    Button {
                        copySelected(from: 0)
                    } label: {
                        Label("左 → 右", systemImage: "arrow.right.doc.on.clipboard")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedLeft == nil)

                    Button {
                        copySelected(from: 1)
                    } label: {
                        Label("右 → 左", systemImage: "arrow.left.doc.on.clipboard")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedRight == nil)

                    Button {
                        openSelected()
                    } label: {
                        Label("编辑", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(activeSelection?.isTextFile != true)
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemBackground))
            }
        }
        .navigationTitle("双窗口管理")
        .navigationBarTitleDisplayMode(.inline)
        .task { refreshBoth() }
        .sheet(item: $editorDocument) { document in
            NavigationStack {
                TextEditorView(title: document.title, initialText: document.initialText, onSave: document.onSave)
            }
        }
        .alert("操作提示", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("确定", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func pane(side: Int) -> some View {
        let directory = side == 0 ? leftDirectory : rightDirectory
        let items = side == 0 ? leftItems : rightItems
        let selected = side == 0 ? selectedLeft : selectedRight

        VStack(spacing: 0) {
            HStack {
                Text(side == 0 ? "左窗口" : "右窗口")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(directory.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button {
                    goUp(side: side)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(directory.standardizedFileURL == LocalFileService.documentsDirectory.standardizedFileURL)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(uiColor: .tertiarySystemBackground))

            List(items) { item in
                Button {
                    activePane = side
                    if item.isDirectory {
                        setDirectory(item.url, side: side)
                    } else {
                        if side == 0 { selectedLeft = item }
                        else { selectedRight = item }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.isDirectory ? "folder.fill" : item.isTextFile ? "doc.text" : "doc")
                            .foregroundStyle(item.isDirectory ? Color.blue : Color.secondary)
                        Text(item.name)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        if selected?.url == item.url {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                        }
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var activeSelection: LocalFileItem? { activePane == 0 ? selectedLeft : selectedRight }

    private func setDirectory(_ url: URL, side: Int) {
        if side == 0 { leftDirectory = url }
        else { rightDirectory = url }
        refresh(side: side)
    }

    private func goUp(side: Int) {
        let current = side == 0 ? leftDirectory : rightDirectory
        let root = LocalFileService.documentsDirectory.standardizedFileURL
        guard current.standardizedFileURL != root else { return }
        let parent = current.deletingLastPathComponent()
        let normalized = parent.path.count < root.path.count ? root : parent
        if side == 0 { leftDirectory = normalized }
        else { rightDirectory = normalized }
        refresh(side: side)
    }

    private func refreshBoth() {
        refresh(side: 0)
        refresh(side: 1)
    }

    private func refresh(side: Int) {
        do {
            if side == 0 { leftItems = try LocalFileService.list(leftDirectory) }
            else { rightItems = try LocalFileService.list(rightDirectory) }
        } catch { errorMessage = error.localizedDescription }
    }

    private func copySelected(from side: Int) {
        let source = side == 0 ? selectedLeft : selectedRight
        let destinationDirectory = side == 0 ? rightDirectory : leftDirectory
        guard let source else { return }
        var destination = destinationDirectory.appendingPathComponent(source.name)
        if FileManager.default.fileExists(atPath: destination.path) {
            let base = source.url.deletingPathExtension().lastPathComponent
            let ext = source.url.pathExtension
            let name = ext.isEmpty ? "\(base)-copy" : "\(base)-copy.\(ext)"
            destination = destinationDirectory.appendingPathComponent(name)
        }
        do {
            try FileManager.default.copyItem(at: source.url, to: destination)
            refresh(side: side == 0 ? 1 : 0)
        } catch { errorMessage = error.localizedDescription }
    }

    private func openSelected() {
        guard let selected = activeSelection, selected.isTextFile else { return }
        do {
            let text = try LocalFileService.readText(selected.url)
            editorDocument = EditorDocument(title: selected.name, initialText: text) { updated in
                try LocalFileService.writeText(updated, to: selected.url)
            }
        } catch { errorMessage = error.localizedDescription }
    }
}

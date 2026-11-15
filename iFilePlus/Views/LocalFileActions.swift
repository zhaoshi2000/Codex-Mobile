import SwiftUI

struct LocalTextFileView: View {
    let url: URL
    @State private var text: String?
    @State private var error: String?
    var body: some View {
        Group {
            if let text {
                TextEditorView(title: url.lastPathComponent, initialText: text) { value in
                    try LocalFileService.writeText(value, to: url)
                }
            } else if let error {
                ContentUnavailableView("无法打开文件", systemImage: "doc.badge.ellipsis", description: Text(error))
            } else { ProgressView("读取文件…") }
        }
        .navigationTitle(url.lastPathComponent)
        .task { do { text = try LocalFileService.readText(url) } catch { self.error = error.localizedDescription } }
    }
}

struct ZipExtractView: View {
    let url: URL
    @State private var output: URL?
    @State private var error: String?
    var body: some View {
        Form {
            Section { Text(url.lastPathComponent) }
            if let output {
                Section {
                    Label("解压完成", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    NavigationLink("打开解压文件夹") { FileBrowserView(directory: output) }
                }
            } else if let error {
                Section("解压失败") { Text(error).foregroundStyle(.red) }
            } else {
                Section { ProgressView("正在解压…"); Text("保存到同目录下的新文件夹，原文件不变。").font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("解压 ZIP")
        .task {
            guard output == nil, error == nil else { return }
            let source = url
            let job = Task.detached(priority: .userInitiated) { try ArchiveService.extractZIP(source) }
            do {
                output = try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
            } catch is CancellationError { self.error = "已取消解压" }
            catch { self.error = "无法解压此 ZIP（可能已损坏、加密或使用不支持的压缩方式）：" + error.localizedDescription }
        }
    }
}

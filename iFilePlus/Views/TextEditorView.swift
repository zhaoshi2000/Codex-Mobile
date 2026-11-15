import SwiftUI
import UIKit

struct TextEditorView: View {
    let title: String
    let onSave: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    @State private var text: String
    @State private var savedText: String
    @State private var fontSize: Double = 15
    @State private var isSaving = false
    @State private var showSearch = false
    @State private var activeAlert: EditorAlert?
    @State private var savedAt: Date?

    init(title: String, initialText: String, onSave: @escaping (String) async throws -> Void) {
        self.title = title
        self.onSave = onSave
        _text = State(initialValue: initialText)
        _savedText = State(initialValue: initialText)
    }

    private var isDirty: Bool { text != savedText }
    private var lineCount: Int { max(1, text.components(separatedBy: .newlines).count) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("UTF-8", systemImage: "character.textbox")
                Spacer()
                Text("\(lineCount) 行 · \(text.count) 字符")
                if isDirty {
                    Text("· 未保存")
                        .foregroundStyle(.orange)
                } else if let savedAt {
                    Text("· 已保存 \(savedAt.formatted(date: .omitted, time: .shortened))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(uiColor: .secondarySystemBackground))

            TextEditor(text: $text)
                .font(.system(size: fontSize, weight: .regular, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .background(Color(uiColor: .systemBackground))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            Divider()
            HStack(spacing: 0) {
                editorAction("查找替换", icon: "magnifyingglass") { showSearch = true }
                editorAction("撤销", icon: "arrow.uturn.backward") { undoManager?.undo() }
                editorAction("重做", icon: "arrow.uturn.forward") { undoManager?.redo() }
                Menu {
                    Button("小号字体", systemImage: "textformat.size.smaller") { fontSize = max(11, fontSize - 1) }
                    Button("标准字体", systemImage: "textformat.size") { fontSize = 15 }
                    Button("大号字体", systemImage: "textformat.size.larger") { fontSize = min(24, fontSize + 1) }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "textformat.size")
                        Text("字体")
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                }
            }
            .foregroundStyle(.blue)
            .background(Color(uiColor: .secondarySystemBackground))
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled(isDirty)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    requestClose()
                } label: {
                    Image(systemName: "chevron.left")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView() }
                    else { Text("保存").fontWeight(.semibold) }
                }
                .disabled(isSaving)
            }
        }
        .sheet(isPresented: $showSearch) {
            SearchReplaceSheet { find, replacement in
                guard !find.isEmpty else { return }
                text = text.replacingOccurrences(of: find, with: replacement)
            }
        }
        .alert(item: $activeAlert) { alert in
            switch alert {
            case .saveError(let message):
                return Alert(title: Text("保存失败"), message: Text(message), dismissButton: .default(Text("确定")))
            case .discardChanges:
                return Alert(
                    title: Text("存在未保存修改"),
                    message: Text("返回将丢失尚未保存的内容。"),
                    primaryButton: .destructive(Text("放弃修改"), action: { dismiss() }),
                    secondaryButton: .cancel(Text("继续编辑"))
                )
            }
        }
    }

    private func editorAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.caption)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
        }
    }

    private func requestClose() {
        if isDirty { activeAlert = .discardChanges }
        else { dismiss() }
    }

    @MainActor
    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await onSave(text)
            savedText = text
            savedAt = Date()
        } catch {
            activeAlert = .saveError(error.localizedDescription)
        }
    }
}

private struct SearchReplaceSheet: View {
    let onReplace: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var findText = ""
    @State private var replacementText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("查找内容") {
                    TextField("输入要查找的文字", text: $findText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("替换为") {
                    TextField("输入替换后的文字", text: $replacementText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Button("全部替换") {
                        onReplace(findText, replacementText)
                        dismiss()
                    }
                    .disabled(findText.isEmpty)
                }
            }
            .navigationTitle("查找与替换")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private enum EditorAlert: Identifiable {
    case saveError(String)
    case discardChanges

    var id: String {
        switch self {
        case .saveError: return "saveError"
        case .discardChanges: return "discardChanges"
        }
    }
}

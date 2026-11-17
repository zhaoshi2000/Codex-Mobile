import SwiftUI

struct CodexMarkdownView: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(ChatMarkdown.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let value): inline(value).frame(maxWidth: .infinity, alignment: .leading)
                case .code(let value):
                    CodexCodeBlock(value: value)
                case .table(let rows):
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                            ForEach(rows.indices, id: \.self) { r in
                                GridRow {
                                    ForEach(0..<(rows.map(\.count).max() ?? 0), id: \.self) { c in
                                        inline(c < rows[r].count ? rows[r][c] : "").fontWeight(r == 0 ? .semibold : .regular).frame(minWidth: 80, maxWidth: 240, alignment: .leading).padding(8).frame(maxHeight: .infinity).background(r == 0 ? Color.secondary.opacity(0.2) : Color.clear).border(Color.secondary.opacity(0.25), width: 0.5)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }.font(.system(size: 15))
    }
    private func inline(_ value: String) -> Text {
        let normalized = ChatMarkdown.links(value)
        let attributed = (try? AttributedString(markdown: normalized, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
        return Text(attributed)
    }
}

private struct CodexCodeBlock: View {
    let value: String
    @State private var copied = false
    @State private var copySequence = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                Button {
                    UIPasteboard.general.string = value
                    copied = true
                    copySequence += 1
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption).padding(.horizontal, 12).frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel(copied ? "命令已复制" : "复制此代码框的完整内容")
                .disabled(value.isEmpty)
            }
            ScrollView(.horizontal) {
                Text(value).font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled).padding(.horizontal, 10).padding(.bottom, 12)
            }
        }
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .task(id: copySequence) {
            guard copySequence > 0 else { return }
            do { try await Task.sleep(for: .seconds(2)); copied = false }
            catch { }
        }
        .onChange(of: value) { _, _ in copied = false }
    }
}

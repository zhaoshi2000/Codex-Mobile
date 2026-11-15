import SwiftUI

struct CodexMarkdownView: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(ChatMarkdown.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let value): inline(value).frame(maxWidth: .infinity, alignment: .leading)
                case .code(let value):
                    ScrollView(.horizontal) { Text(value).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).padding(10) }.background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
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

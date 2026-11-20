import SwiftUI
import UIKit

struct CodexMarkdownView: View {
    let text: String
    var textColor: UIColor = .label
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(ChatMarkdown.selectionBlocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let value):
                    CodexSelectableText(text: value, textColor: textColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
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

private struct CodexTextSelectionKey: EnvironmentKey {
    static let defaultValue: (UUID, Bool) -> Void = { _, _ in }
}

extension EnvironmentValues {
    var codexTextSelectionChanged: (UUID, Bool) -> Void {
        get { self[CodexTextSelectionKey.self] }
        set { self[CodexTextSelectionKey.self] = newValue }
    }
}

// SwiftUI Text's iOS selection menu copies a whole block. A noneditable
// UITextView provides the system selection handles without opening a keyboard.
struct CodexSelectableText: UIViewRepresentable {
    let text: String
    var textColor: UIColor = .label
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 15
    @Environment(\.openURL) private var openURL
    @Environment(\.codexTextSelectionChanged) private var selectionChanged

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> CodexSelectionTextView {
        let view = CodexSelectionTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        view.selectionEnded = { [weak coordinator = context.coordinator] in coordinator?.reportSelection(false) }
        return view
    }

    func updateUIView(_ view: CodexSelectionTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.openLink = { openURL($0) }
        coordinator.selectionChanged = selectionChanged
        coordinator.update(view, text: text, fontSize: fontSize, color: textColor)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: CodexSelectionTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    static func dismantleUIView(_ view: CodexSelectionTextView, coordinator: Coordinator) {
        view.delegate = nil
        view.selectionEnded = nil
        coordinator.reportSelection(false)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let id = UUID()
        var openLink: (URL) -> Void = { _ in }
        var selectionChanged: (UUID, Bool) -> Void = { _, _ in }
        private var source: String?
        private var fontSize: CGFloat = 0
        private var color: UIColor?
        private var updating = false
        private var hasSelection = false

        func update(_ view: UITextView, text: String, fontSize: CGFloat, color: UIColor) {
            // Background status updates must not reset a user's handles or
            // repeatedly parse/render an unchanged reply.
            guard source != text || self.fontSize != fontSize || self.color != color else { return }
            source = text; self.fontSize = fontSize; self.color = color
            let previous = view.attributedText?.string ?? ""
            let selected = view.selectedRange
            let value = Self.attributed(text, fontSize: fontSize, color: color)
            updating = true
            view.attributedText = value
            // Streaming may append after the selected passage. Keep its range
            // only when the prefix is unchanged, never select unrelated text.
            let end = NSMaxRange(selected)
            if selected.location != NSNotFound, selected.length > 0,
               end <= (previous as NSString).length, end <= value.length,
               (previous as NSString).substring(to: end) == (value.string as NSString).substring(to: end) {
                view.selectedRange = selected
            } else { view.selectedRange = NSRange(location: 0, length: 0) }
            updating = false
            reportSelection(view.selectedRange.length > 0)
            view.invalidateIntrinsicContentSize()
        }

        static func attributed(_ text: String, fontSize: CGFloat, color: UIColor) -> NSAttributedString {
            let parsed = (try? AttributedString(markdown: ChatMarkdown.links(text), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
            let result = NSMutableAttributedString(string: "")
            for run in parsed.runs {
                let intent = run.inlinePresentationIntent ?? []
                var font = intent.contains(.code) ? UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) : UIFont.systemFont(ofSize: fontSize)
                var traits = font.fontDescriptor.symbolicTraits
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: descriptor, size: fontSize) }
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link { attributes[.link] = link }
                result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
            }
            return result
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if !updating { reportSelection(textView.selectedRange.length > 0) }
        }
        func reportSelection(_ active: Bool) {
            guard hasSelection != active else { return }
            hasSelection = active
            let callback = selectionChanged, id = id
            // Delegate calls can occur during a SwiftUI view update.
            DispatchQueue.main.async { callback(id, active) }
        }
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content else { return defaultAction }
            return UIAction { [weak self] _ in self?.openLink(url) }
        }
    }
}

final class CodexSelectionTextView: UITextView {
    var selectionEnded: (() -> Void)?
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { selectedRange = NSRange(location: 0, length: 0); selectionEnded?() }
        return resigned
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

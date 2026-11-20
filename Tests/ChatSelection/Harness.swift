import SwiftUI

@main
struct SelectionHarness: App {
    var body: some Scene { WindowGroup { SelectionScreen() } }
}

private let sample = "第一段：模型比例改变。\n\n第二段 **重点文字**，只复制这一小段，不需要整条回复。\n\n[下载报告](D:/report.pdf) 与 [网页](https://example.com)。"

struct SelectionScreen: View {
    @State private var result = "Ready"
    @State private var selected = false
    var body: some View {
        VStack {
            Text(result).accessibilityIdentifier("result")
            Text(selected ? "Selection active" : "No selection")
            ScrollView {
                CodexMarkdownView(text: sample)
                    .padding(16)
                    .environment(\.openURL, OpenURLAction { url in
                        result = url.scheme == "ifilepc" ? "File routed" : "Web routed"
                        return .handled
                    })
                    .environment(\.codexTextSelectionChanged) { _, active in selected = active }
            }
            Button("Check selection and rendering") { result = check() }
        }.padding().preferredColorScheme(.dark)
    }

    private func check() -> String {
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let view = windows.flatMap({ descendants($0) }).compactMap({ $0 as? CodexSelectionTextView }).first,
              let coordinator = view.delegate as? CodexSelectableText.Coordinator else { return "FAIL missing selectable body" }
        guard !view.isEditable, view.isSelectable, !view.isScrollEnabled else { return "FAIL native selection configuration" }
        let text = view.attributedText.string as NSString
        let partial = "模型比例改变。\n\n第二段"
        let range = text.range(of: partial)
        guard range.location != NSNotFound else { return "FAIL cross-paragraph selection" }
        view.becomeFirstResponder()
        view.selectedRange = range
        view.copy(nil)
        guard UIPasteboard.general.string == partial else { return "FAIL partial copy" }
        let boldRange = text.range(of: "重点文字")
        guard let bold = view.attributedText.attribute(.font, at: boldRange.location, effectiveRange: nil) as? UIFont,
              bold.fontDescriptor.symbolicTraits.contains(.traitBold) else { return "FAIL bold lost" }
        let linkRange = text.range(of: "下载报告")
        guard let link = view.attributedText.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL,
              link.scheme == "ifilepc" else { return "FAIL file link lost" }
        let fontSize = (view.attributedText.attribute(.font, at: 0, effectiveRange: nil) as! UIFont).pointSize
        coordinator.update(view, text: sample + " 后续输出", fontSize: fontSize, color: .label)
        guard view.selectedRange == range else { return "FAIL selection reset by streaming" }
        view.copy(nil)
        guard UIPasteboard.general.string == partial else { return "FAIL copied wrong range after streaming" }
        coordinator.update(view, text: sample + " 后续输出", fontSize: fontSize, color: .label)
        guard view.selectedRange == range else { return "FAIL selection reset by unchanged refresh" }
        let narrow = view.sizeThatFits(CGSize(width: 220, height: CGFloat.greatestFiniteMagnitude))
        let wide = view.sizeThatFits(CGSize(width: 390, height: CGFloat.greatestFiniteMagnitude))
        guard narrow.height > wide.height, wide.height > 70 else { return "FAIL multiline sizing" }
        coordinator.update(view, text: "替换成不同内容", fontSize: fontSize, color: .label)
        guard view.selectedRange.length == 0 else { return "FAIL stale selection" }
        coordinator.update(view, text: sample, fontSize: fontSize, color: .label)
        _ = view.resignFirstResponder()
        return "PASS copy, paragraphs, bold, links, streaming, sizing"
    }
}

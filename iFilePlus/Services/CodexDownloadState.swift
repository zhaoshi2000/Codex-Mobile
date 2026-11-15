import Foundation

struct CodexDownloadState {
    enum Phase { case preparing, receiving, verifying, cancelling, saved, failed, cancelled }
    var name: String
    var phase: Phase = .preparing
    var received = 0
    var total: Int?
    var file: URL?
    var error: String?
    var preview = false
    var active: Bool { [.preparing, .receiving, .verifying, .cancelling].contains(phase) }
    var progress: Double? {
        guard let total else { return nil }
        if total == 0 { return phase == .preparing ? 0 : 1 }
        return min(1, max(0, Double(received) / Double(total)))
    }
    var title: String {
        switch phase {
        case .preparing: return "正在准备下载…"
        case .receiving: return "正在下载 · \(Int((progress ?? 0) * 100))%"
        case .verifying: return "下载已接收，正在校验…"
        case .cancelling: return "正在取消下载…"
        case .saved: return preview ? "预览文件已准备好" : "下载成功"
        case .failed: return "下载失败"
        case .cancelled: return "下载已取消"
        }
    }
    var sizeLabel: String {
        let received = ByteCountFormatter.string(fromByteCount: Int64(received), countStyle: .file)
        guard let total else { return "正在获取文件大小" }
        return received + " / " + ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }
}

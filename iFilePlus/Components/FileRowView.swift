import SwiftUI

struct FileRowView: View {
    let item: LocalFileItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(item.isDirectory ? Color.blue : Color.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(item.isDirectory ? "文件夹" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    if let modified = item.modified {
                        Text("·")
                        Text(modified.formatted(date: .numeric, time: .shortened))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var iconName: String {
        if item.isDirectory { return "folder.fill" }
        switch item.url.pathExtension.lowercased() {
        case "txt", "md", "log": return "doc.text"
        case "jpg", "jpeg", "png", "heic": return "photo"
        case "mp4", "mov": return "video"
        case "zip", "7z", "rar": return "archivebox"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }
}

struct RemoteFileRowView: View {
    let item: RemoteFileEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.text")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(item.isDirectory ? Color.blue : Color.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

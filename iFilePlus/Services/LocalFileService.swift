import Foundation
import UniformTypeIdentifiers
import CoreFoundation

struct LocalFileItem: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let isDirectory: Bool
    let size: Int64
    let modified: Date?

    var name: String { url.lastPathComponent }
    var isTextFile: Bool { !isDirectory && LocalFileService.textExtensions.contains(url.pathExtension.lowercased()) }
}

enum LocalFileService {
    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "log", "ini", "conf", "cfg", "json", "xml", "yaml", "yml",
        "html", "htm", "css", "js", "ts", "jsx", "tsx", "py", "php", "java", "kt", "swift",
        "c", "h", "cpp", "hpp", "sh", "bat", "sql", "csv", "properties", "toml", "env"
    ]

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func list(_ directory: URL) throws -> [LocalFileItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey],
            options: [.skipsPackageDescendants]
        )
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]),
                  !url.lastPathComponent.hasPrefix(".ifile-extract-") else { return nil }
            return LocalFileItem(
                url: url,
                isDirectory: values.isDirectory == true,
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate
            )
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func createFolder(named name: String, in directory: URL) throws {
        let safe = sanitizedName(name)
        guard !safe.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(safe, isDirectory: true), withIntermediateDirectories: false)
    }

    static func createTextFile(named name: String, in directory: URL) throws -> URL {
        var safe = sanitizedName(name)
        guard !safe.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        if URL(fileURLWithPath: safe).pathExtension.isEmpty { safe += ".txt" }
        return try createFile(named: safe, in: directory)
    }

    static func createFile(named name: String, in directory: URL) throws -> URL {
        let safe = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty, safe != ".", safe != "..", !safe.contains("/"), !safe.contains("\\"), !safe.contains("\0") else { throw CocoaError(.fileWriteInvalidFileName) }
        let url = directory.appendingPathComponent(safe)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        try Data().write(to: url, options: .atomic)
        return url
    }

    static func createMarkdownFile(named name: String, in directory: URL) throws -> URL {
        let safe = sanitizedName(name)
        guard !safe.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        let fileName = safe.lowercased().hasSuffix(".md") ? safe : safe + ".md"
        return try createTextFile(named: fileName, in: directory)
    }

    static func rename(_ url: URL, to newName: String) throws {
        let safe = sanitizedName(newName)
        guard !safe.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        let destination = url.deletingLastPathComponent().appendingPathComponent(safe)
        try FileManager.default.moveItem(at: url, to: destination)
    }

    static func duplicate(_ url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var suffix = 1
        var destination: URL
        repeat {
            let name = ext.isEmpty ? "\(base) 副本 \(suffix)" : "\(base) 副本 \(suffix).\(ext)"
            destination = directory.appendingPathComponent(name)
            suffix += 1
        } while FileManager.default.fileExists(atPath: destination.path)
        try FileManager.default.copyItem(at: url, to: destination)
    }

    static func moveToRoot(_ url: URL) throws {
        let root = documentsDirectory.standardizedFileURL
        guard url.deletingLastPathComponent().standardizedFileURL != root else { return }
        var destination = root.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let suffix = UUID().uuidString.prefix(6)
            let name = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
            destination = root.appendingPathComponent(name)
        }
        try FileManager.default.moveItem(at: url, to: destination)
    }

    static func delete(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    static func readText(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 5 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 5 * 1024 * 1024 else { throw ArchiveService.ExtractionError(detail: "文本编辑器支持不超过 5 MB 的文件。") }
        let unicodeBOM = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) || data.starts(with: [0, 0, 0xFE, 0xFF])
        guard !data.contains(0) || unicodeBOM else { throw ArchiveService.ExtractionError(detail: "此文件包含二进制数据，不能作为文本编辑。") }
        return decodeText(data)
    }

    /// Tries common Unicode encodings first, then Chinese legacy encodings.
    /// Text is saved as UTF-8 by writeText(), so an edited legacy file is normalized safely.
    static func decodeText(_ data: Data) -> String {
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0632)))
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0631)))
        let encodings: [String.Encoding] = [
            .utf8, .utf16, .utf16LittleEndian, .utf16BigEndian,
            gb18030, gbk, .isoLatin1
        ]
        for encoding in encodings {
            if let value = String(data: data, encoding: encoding) {
                return value.replacingOccurrences(of: "\u{FEFF}", with: "")
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func writeText(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    static func importFiles(_ urls: [URL], into directory: URL) throws {
        for source in urls {
            let accessed = source.startAccessingSecurityScopedResource()
            defer { if accessed { source.stopAccessingSecurityScopedResource() } }
            var destination = directory.appendingPathComponent(source.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                let base = source.deletingPathExtension().lastPathComponent
                let ext = source.pathExtension
                let suffix = UUID().uuidString.prefix(6)
                let name = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
                destination = directory.appendingPathComponent(name)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    private static func sanitizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
    }
}

import Foundation
import ZIPFoundation

enum ArchiveService {
    struct ExtractionError: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }
    static func extractZIP(_ source: URL) throws -> URL {
        let archive = try Archive(url: source, accessMode: .read)
        let manager = FileManager.default
        let parent = source.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".ifile-extract-" + UUID().uuidString, isDirectory: true)
        let maxBytes: UInt64 = 512 * 1024 * 1024
        var names = Set<String>(); var declared: UInt64 = 0; var count = 0
        // Validate the entire directory before writing. Links are never materialized.
        for entry in archive {
            count += 1
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            let name = entry.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            guard count <= 5000, !entry.path.hasPrefix("/"), !entry.path.contains("\\"), !entry.path.contains(":"),
                  !parts.contains(".."), !parts.contains("."), !name.isEmpty, names.insert(name).inserted,
                  entry.type != .symlink else { throw ExtractionError(detail: "压缩包包含不安全、重复的路径或过多文件，已取消解压。") }
            guard entry.uncompressedSize <= maxBytes - declared else { throw ExtractionError(detail: "解压后的内容不能超过 512 MB。") }
            declared += entry.uncompressedSize
        }
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        var written: UInt64 = 0
        for entry in archive {
            try Task.checkCancellation()
            let destination = staging.appendingPathComponent(entry.path).standardizedFileURL
            guard destination.path.hasPrefix(staging.standardizedFileURL.path + "/") else { throw ExtractionError(detail: "压缩包路径无效") }
            if entry.type == .directory {
                try manager.createDirectory(at: destination, withIntermediateDirectories: true)
                continue
            }
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard manager.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            var entryBytes: UInt64 = 0
            let checksum = try archive.extract(entry, bufferSize: 64 * 1024) { bytes in
                try Task.checkCancellation()
                guard UInt64(bytes.count) <= maxBytes - written else { throw ExtractionError(detail: "解压内容超过大小限制") }
                written += UInt64(bytes.count); entryBytes += UInt64(bytes.count)
                try handle.write(contentsOf: bytes)
            }
            guard checksum == entry.checksum, entryBytes == entry.uncompressedSize else { throw ExtractionError(detail: "压缩包内容校验失败，请重新下载文件。") }
            try handle.close()
        }
        let base = source.deletingPathExtension().lastPathComponent
        var output = parent.appendingPathComponent(base + " 解压", isDirectory: true)
        if manager.fileExists(atPath: output.path) { output = parent.appendingPathComponent(base + " 解压-" + String(UUID().uuidString.prefix(6)), isDirectory: true) }
        try manager.moveItem(at: staging, to: output)
        return output
    }
}

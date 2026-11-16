import Foundation
import CryptoKit

/// Original preview files have a separate bounded cache; thumbnail eviction and
/// dismissing a modal must not force another download of the original attachment.
actor CodexPreviewCache {
    static let shared = CodexPreviewCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexPreviews", isDirectory: true))
    private let directory: URL
    private let budget: Int
    private var pending: [String: Task<URL, Error>] = [:]
    init(directory: URL, budget: Int = 256 * 1024 * 1024) { self.directory = directory; self.budget = budget }
    func file(for key: String, load: @escaping @Sendable () async throws -> URL) async throws -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        if let task = pending[hash] { return try await task.value }
        let folder = directory.appendingPathComponent(hash, isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]),
           let file = files.first,
           let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(date) < 7 * 86400 {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return file.resolvingSymlinksInPath()
        }
        let task = Task { try self.store(try await load(), in: folder) }
        pending[hash] = task
        defer { pending[hash] = nil }
        return try await task.value
    }
    private func store(_ source: URL, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.copyItem(at: source, to: target)
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
        #endif
        // download(preview:) creates a dedicated temporary folder, never Documents.
        if source.deletingLastPathComponent().lastPathComponent.hasPrefix("codex-preview-") {
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
        }
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let files = folders.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? [] }
        let entries = files.compactMap { file -> (URL, Int, Date)? in
            guard let info = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (file, info.fileSize ?? 0, info.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 > $1.2 }
        var bytes = 0
        for (index, entry) in entries.enumerated() {
            bytes += entry.1
            if entry.0 != target && (index >= 40 || bytes > budget || Date().timeIntervalSince(entry.2) > 7 * 86400) {
                try? FileManager.default.removeItem(at: entry.0.deletingLastPathComponent())
            }
        }
        return target.resolvingSymlinksInPath()
    }
}

// Small disposable thumbnails only. Original photos and full chat history are not cached here.
actor CodexThumbnailCache {
    static let shared = CodexThumbnailCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexThumbnails", isDirectory: true))
    private let directory: URL
    private let budget: Int
    private var pending: [String: Task<Data, Error>] = [:]
    init(directory: URL, budget: Int = 16 * 1024 * 1024) { self.directory = directory; self.budget = budget }
    func data(for key: String, load: @escaping @Sendable () async throws -> Data) async throws -> Data {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        if let task = pending[hash] { return try await task.value }
        let file = directory.appendingPathComponent(hash)
        if let info = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
           let date = info.contentModificationDate, Date().timeIntervalSince(date) < 7 * 86400,
           (info.fileSize ?? Int.max) <= 150000, let data = try? Data(contentsOf: file) { return data }
        // A disappearing SwiftUI row must not cancel the shared request before it is cached.
        let task = Task { try await load() }
        pending[hash] = task
        defer { pending[hash] = nil }
        let data = try await task.value
        if !data.isEmpty && data.count <= 150000 {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(iOS)
            try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try? data.write(to: file, options: .atomic)
            #endif
            prune()
        }
        return data
    }
    private func prune() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let entries = files.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 > $1.2 }
        var bytes = 0
        for (index, entry) in entries.enumerated() {
            bytes += entry.1
            if index >= 120 || bytes > budget || Date().timeIntervalSince(entry.2) > 7 * 86400 { try? FileManager.default.removeItem(at: entry.0) }
        }
    }
}

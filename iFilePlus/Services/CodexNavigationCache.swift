import Foundation
import Combine

struct CodexConnectionRecovery {
    private var attempt = 0
    private var openedConversation = false

    mutating func nextRetryDelay() -> Int {
        let delays = [1, 2, 4, 8, 15, 30]
        let delay = delays[attempt]
        attempt = min(attempt + 1, delays.count - 1)
        return delay
    }

    mutating func transportReady() {
        attempt = 0
        resetConversation()
    }

    mutating func resetConversation() { openedConversation = false }

    mutating func shouldOpenConversation(desktopState: String?, writable: Bool) -> Bool {
        if writable { resetConversation(); return false }
        guard !openedConversation, desktopState == nil || desktopState == "ready" else { return false }
        openedConversation = true
        return true
    }
}

// A chat connection survives cancellation of the SwiftUI task waiting for it.
@MainActor
final class CodexChatSelection {
    private var task: Task<Void, Never>?
    private var thread: String?
    private var token = UUID()
    var isRunning: Bool { task != nil }
    func isCurrent(_ value: UUID, threadID: String) -> Bool { token == value && thread == threadID }
    func run(_ threadID: String, operation: @escaping @MainActor (UUID) async -> Void) async {
        if thread == threadID, let task { await task.value; return }
        cancel()
        thread = threadID
        let current = token
        let work = Task { await operation(current) }
        task = work
        await work.value
        if token == current { task = nil }
    }
    func cancel() { token = UUID(); task?.cancel(); task = nil; thread = nil }
}

struct CodexRow: Identifiable, Hashable {
    let id: String
    let title: String
    var path: String = ""
    var directory: Bool = false
    var size: Int = 0
}

/// One cache per paired device, independent of the lifetime of the drawer view.
@MainActor final class CodexNavigationCache: ObservableObject {
    typealias Request = (String, [String: Any]) async throws -> [String: Any]
    struct Page {
        var rows: [CodexRow] = []
        var cursor: String?
        var checkedAt: Date?
    }
    @Published private(set) var projects: [CodexRow] = []
    @Published private(set) var pages: [String: Page] = [:]
    @Published private(set) var loading: Set<String> = []
    @Published private(set) var error: String?
    @Published var expanded: Set<String> = []
    @Published var projectsExpanded = false
    private var projectsCheckedAt: Date?
    private var loadingProjects = false
    private var deleted: Set<String> = []
    private let request: Request
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init, request: @escaping Request) {
        self.now = now; self.request = request
    }
    func page(_ project: String = "") -> Page { pages[project] ?? Page() }

    // The host/project screens have already paid for these requests. Reuse them
    // on the first drawer open instead of asking the PC for the same data again.
    func seed(_ method: String, params: [String: Any], result: [String: Any]) {
        if method == "projects" || method == "navigation", projectsCheckedAt == nil {
            setProjects(result)
        }
        if method == "threads", params["cursor"] == nil {
            let key = params["projectId"] as? String ?? ""
            if pages[key] == nil { merge(result, key: key, more: false) }
        }
    }
    func remove(_ id: String) {
        deleted.insert(id)
        for key in Array(pages.keys) { pages[key]?.rows.removeAll { $0.id == id } }
        invalidate()
    }
    func invalidate() {
        projectsCheckedAt = nil
        for key in Array(pages.keys) { pages[key]?.checkedAt = nil }
    }
    func refresh(force: Bool = false) async {
        async let projectList: Void = refreshProjects(force: force)
        async let recent: Void = load(force: force)
        _ = await (projectList, recent)
        for id in expanded { await load(id, force: force) }
    }
    private func setProjects(_ result: [String: Any]) {
        projects = (result["projects"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? String else { return nil }
            return CodexRow(id: id, title: $0["name"] as? String ?? "项目")
        }
        projectsCheckedAt = now()
        let valid = Set(projects.map(\.id))
        expanded.formIntersection(valid)
        for key in Array(pages.keys) where !key.isEmpty && !valid.contains(key) { pages.removeValue(forKey: key) }
    }
    private func refreshProjects(force: Bool) async {
        guard !loadingProjects else { return }
        if !force, let date = projectsCheckedAt, now().timeIntervalSince(date) < 60 { return }
        loadingProjects = true; defer { loadingProjects = false }
        do { setProjects(try await request("projects", [:])) }
        catch { self.error = error.localizedDescription }
    }
    func load(_ key: String = "", more: Bool = false, force: Bool = false) async {
        guard !loading.contains(key) else { return }
        let old = page(key)
        if more && old.cursor == nil { return }
        if !more && !force, let date = old.checkedAt, now().timeIntervalSince(date) < 10 { return }
        loading.insert(key); error = nil; defer { loading.remove(key) }
        do {
            var cursor = more ? old.cursor : nil
            var recoveredCursor = false
            var visited: Set<String> = []
            // After a head refresh the cursor starts at the new first page.
            // Skip cached overlap only when the user explicitly asks for more.
            while true {
                var params: [String: Any] = ["limit": 20]
                if !key.isEmpty { params["projectId"] = key }
                if let cursor { params["cursor"] = cursor }
                let result: [String: Any]
                do { result = try await request("threads", params) }
                catch {
                    if more, cursor != nil, !recoveredCursor,
                       error.localizedDescription.contains("列表已更新") {
                        cursor = nil; recoveredCursor = true; continue
                    }
                    throw error
                }
                let previousCount = page(key).rows.count
                merge(result, key: key, more: more)
                guard more, page(key).rows.count == previousCount,
                      let next = page(key).cursor, visited.insert(next).inserted else { break }
                cursor = next
            }
        } catch { self.error = error.localizedDescription }
    }
    private func merge(_ result: [String: Any], key: String, more: Bool) {
        let rows = (result["threads"] as? [[String: Any]] ?? []).compactMap { row -> CodexRow? in
            guard let id = row["id"] as? String, !deleted.contains(id) else { return nil }
            return CodexRow(id: id, title: row["title"] as? String ?? "对话", path: row["projectName"] as? String ?? "未分组")
        }
        let next = result["nextCursor"] as? String
        let old = page(key)
        let updated = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        let candidates = more ? old.rows.map { updated[$0.id] ?? $0 } + rows : rows + (next == nil ? [] : old.rows)
        var seen: Set<String> = []
        pages[key] = Page(rows: candidates.filter { seen.insert($0.id).inserted }, cursor: next,
                          checkedAt: more ? old.checkedAt : now())
    }
}

import Foundation
import SwiftUI

struct OpenClawSessionRow: Identifiable {
    let id: String
    let title: String
    let active: Bool
}

@MainActor final class OpenClawService: ObservableObject {
    @Published var connected = false
    @Published var busy = false
    @Published var sending = false
    @Published var running = false
    @Published var uncertain = false
    @Published var deliveryPending = false
    @Published var error: String?
    @Published var sessions: [OpenClawSessionRow] = []
    @Published var messages: [CodexChatMessage] = []
    @Published var selected = ""
    @Published var showTrust = false
    @Published var fingerprint = ""
    private var connection: ServerConnection
    private var ssh: SSHSession?
    private var pendingKey: String?
    private var runID: String?
    private var requestID: String?
    private var pendingText: String?
    private var pendingSession: String?
    private var refreshing = false
    private var generation = UUID()
    private var baseline = Set<String>()
    private var pendingAccount: String { "openclaw.pending." + connection.id.uuidString }
    init(connection: ServerConnection) { self.connection = connection; selected = connection.openClawSession ?? "agent:main:main" }

    func connect(store: ConnectionStore) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        generation = UUID(); error = nil
        if let latest = store.connections.first(where: { $0.id == connection.id }) { connection = latest }
        await ssh?.disconnect(); connected = false
        do {
            if connection.trustedHostKey == nil {
                let key = try await SSHService.discoverHostKey(host: connection.host, port: connection.port)
                pendingKey = key; fingerprint = try SSHService.fingerprint(for: key); showTrust = true; return
            }
            let session = SSHSession()
            try await session.connect(connection: connection, password: store.password(for: connection.id) ?? "", privateKey: store.privateKey(for: connection.id), enableSFTP: false)
            ssh = session
            if let saved = KeychainStore.get(account: pendingAccount), let data = saved.data(using: .utf8), let p = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = p["id"] as? String, let text = p["text"] as? String, let key = p["session"] as? String {
                requestID = id; pendingText = text; pendingSession = key; selected = key; uncertain = true; deliveryPending = true; baseline = Set(p["baseline"] as? [String] ?? [])
            }
            try await loadSessions(); connected = true; await refresh()
        } catch { self.error = error.localizedDescription; await ssh?.disconnect(); ssh = nil }
    }
    func trust(store: ConnectionStore) async {
        guard let key = pendingKey else { return }; connection.trustedHostKey = key; store.update(connection); showTrust = false; await connect(store: store)
    }
    private func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        guard let ssh else { throw OpenClawWireError.remote("SSH 尚未连接") }
        let command = try OpenClawProtocol.command(executable: connection.openClawExecutable ?? "openclaw", container: connection.openClawContainer ?? "", method: method, params: params)
        return try OpenClawProtocol.decode(await ssh.execute(command))
    }
    func loadSessions() async throws {
        let result = try await call("sessions.list", ["limit": 50])
        sessions = (result["sessions"] as? [[String: Any]] ?? []).compactMap { value in
            guard let key = value["key"] as? String else { return nil }
            return OpenClawSessionRow(id: key, title: value["displayName"] as? String ?? value["label"] as? String ?? value["derivedTitle"] as? String ?? key, active: value["hasActiveRun"] as? Bool ?? false)
        }
        if !sessions.contains(where: { $0.id == selected }) { sessions.insert(OpenClawSessionRow(id: selected, title: selected, active: false), at: 0) }
    }
    func select(_ key: String) async { guard !sending && !deliveryPending else { return }; selected = key; messages = []; runID = nil; running = false; await refresh() }
    func refresh() async {
        guard connected, !refreshing else { return }; refreshing = true; defer { refreshing = false }
        let key = selected, token = generation
        do {
            let result = try await call("chat.history", ["sessionKey": key, "limit": 50])
            guard key == selected, token == generation else { return }
            let rows = (result["messages"] as? [[String: Any]] ?? []).enumerated().compactMap { index, value -> CodexChatMessage? in
                let role = value["role"] as? String ?? ""
                guard role == "assistant" || role == "user" else { return nil }
                let text = OpenClawProtocol.text(value)
                guard !text.isEmpty else { return nil }
                return CodexChatMessage(["id": value["id"] as? String ?? "\(value["timestamp"] ?? index)-\(index)", "role": role, "text": text])
            }
            messages = rows
            if let id = requestID, pendingSession == key, let text = pendingText {
                if rows.contains(where: { $0.role == "user" && $0.text == text && !baseline.contains($0.id) }) { clearPending() }
                else { messages.append(CodexChatMessage(id: id, text: text, delivery: uncertain ? "送达待确认" : "已送达")) }
            }
            let info = result["sessionInfo"] as? [String: Any]
            if let active = info?["hasActiveRun"] as? Bool { running = active }
            else if result["inFlightRun"] != nil { running = result["inFlightRun"] is [String: Any] }
            else if rows.contains(where: { $0.role == "assistant" && !baseline.contains($0.id) }) { running = false }
            if let flight = result["inFlightRun"] as? [String: Any] { runID = flight["runId"] as? String ?? flight["id"] as? String }
        } catch { if generation == token { self.error = error.localizedDescription } }
    }
    func send(_ text: String) async {
        guard connected, !sending else { return }
        if requestID == nil {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 32000 else { error = "消息需为 1–32000 个字符"; return }
            deliveryPending = true; requestID = UUID().uuidString; pendingText = text; pendingSession = selected; baseline = Set(messages.map(\.id))
        }
        guard let id = requestID, let value = pendingText, let key = pendingSession else { return }
        sending = true; defer { sending = false }
        if !messages.contains(where: { $0.id == id }) { messages.append(CodexChatMessage(id: id, text: value, delivery: "正在发送…")) }
        do {
            let saved = try JSONSerialization.data(withJSONObject: ["id": id, "text": value, "session": key, "baseline": Array(baseline)])
            try KeychainStore.set(String(decoding: saved, as: UTF8.self), account: pendingAccount)
            let result = try await call("chat.send", ["sessionKey": key, "message": value, "idempotencyKey": id, "deliver": false])
            runID = result["runId"] as? String; running = true; uncertain = false; error = nil
            if let i = messages.firstIndex(where: { $0.id == id }) { messages[i].delivery = "已送达" }
            await refresh()
        } catch { uncertain = true; self.error = error.localizedDescription; if let i = messages.firstIndex(where: { $0.id == id }) { messages[i].delivery = "送达待确认" } }
    }
    func clearPending() { deliveryPending = false; requestID = nil; pendingText = nil; pendingSession = nil; uncertain = false; KeychainStore.delete(account: pendingAccount) }
    func stop() async { do { var p: [String: Any] = ["sessionKey": selected]; if let runID { p["runId"] = runID }; _ = try await call("chat.abort", p); await refresh() } catch { self.error = error.localizedDescription } }
    func disconnect() async { generation = UUID(); connected = false; await ssh?.disconnect(); ssh = nil }
}

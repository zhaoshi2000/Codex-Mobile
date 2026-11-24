import Foundation
import CryptoKit
import SwiftUI
import ImageIO
import Network

struct CodexDevice: Codable, Identifiable {
    var id: String { hostId }
    let version: Int
    let relay: String
    let hostId: String
    let hostName: String
    let hostKey: String
    var pairToken: String?
    var expires: Double?
    var alias: String?
    var displayName: String { alias?.isEmpty == false ? alias! : hostName }
}

struct CodexConnectError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct CodexQuotaWindow: Identifiable {
    let id: String
    let label: String
    let remaining: Double
    let resetsAt: Date?
}

extension Data {
    init?(codexBase64URL value: String) {
        var s = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        self.init(base64Encoded: s)
    }
    var codexBase64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

@MainActor final class CodexDeviceStore: ObservableObject {
    @Published var devices: [CodexDevice] = []
    init() {
        if let data = UserDefaults.standard.data(forKey: "codex.devices.v1"), let saved = try? JSONDecoder().decode([CodexDevice].self, from: data) { devices = saved }
    }
    @discardableResult func add(_ uri: String) throws -> CodexDevice {
        guard let url = URLComponents(string: uri.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "ifilecodex", url.host == "pair",
              let encoded = url.queryItems?.first(where: { $0.name == "data" })?.value,
              let data = Data(codexBase64URL: encoded), data.count < 8192 else { throw CodexConnectError(message: "请扫描电脑连接程序生成的二维码，或粘贴完整配对链接。") }
        var device = try JSONDecoder().decode(CodexDevice.self, from: data)
        guard device.version == 1, UUID(uuidString: device.hostId) != nil,
              Data(codexBase64URL: device.hostKey)?.count == 32,
              let relay = URLComponents(string: device.relay), relay.scheme == "wss", relay.host != nil,
              relay.user == nil, relay.password == nil, relay.query == nil, relay.fragment == nil,
              !relay.path.contains("..") else { throw CodexConnectError(message: "配对格式不受支持。手机连接需要 wss:// 加密中转地址。") }
        guard let token = device.pairToken, token.count >= 32, (device.expires ?? 0) > Date().timeIntervalSince1970 * 1000 else { throw CodexConnectError(message: "配对码已过期，请在电脑重新启动连接程序。") }
        if let old = devices.first(where: { $0.id == device.id }), old.hostKey != device.hostKey { throw CodexConnectError(message: "电脑的身份密钥已改变。请核实后先移除旧设备，再重新配对。") }
        try KeychainStore.set(token, account: "codex.pair." + device.id)
        device.alias = devices.first(where: { $0.id == device.id })?.alias
        device.pairToken = nil; device.expires = nil
        devices.removeAll { $0.id == device.id }; devices.append(device); save()
        return device
    }
    func remove(_ device: CodexDevice) {
        CodexConnectService.remove(device.id); devices.removeAll { $0.id == device.id }; KeychainStore.delete(account: "codex.pair." + device.id); save()
    }
    func rename(_ device: CodexDevice, to value: String) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        let name = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !name.isEmpty else { return }
        devices[index].alias = name
        CodexConnectService.session(for: devices[index]).device = devices[index]
        save()
    }
    private func save() { if let data = try? JSONEncoder().encode(devices) { UserDefaults.standard.set(data, forKey: "codex.devices.v1") } }
}

// Keeps only the selected conversation in memory. It never imports the PC's history database.
@MainActor final class CodexConnectService: ObservableObject {
    lazy var navigationCache = CodexNavigationCache { [weak self] method, params in
        guard let self else { throw CodexConnectError(message: "电脑连接已关闭") }
        return try await self.request(method, params)
    }
    @Published var connected = false
    @Published var quota: [CodexQuotaWindow] = []
    @Published var quotaMessage = "连接电脑后可查看 Codex 额度"
    @Published var quotaLoading = false
    @Published var quotaCheckedAt: Date?
    func refreshQuota(force: Bool = false) async {
        guard connected, !quotaLoading else { return }
        if !force, let quotaCheckedAt, Date().timeIntervalSince(quotaCheckedAt) < 60 { return }
        quotaLoading = true; defer { quotaLoading = false }
        do {
            let data = try await request("quota")
            quota = (data["available"] as? Bool == false ? [] : data["windows"] as? [[String: Any]] ?? []).compactMap { row in
                guard let id = row["id"] as? String, let label = row["label"] as? String, let remaining = row["remainingPercent"] as? Double else { return nil }
                return CodexQuotaWindow(id: id, label: label, remaining: remaining, resetsAt: (row["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) })
            }
            quotaMessage = data["message"] as? String ?? "暂时无法读取额度"
            quotaCheckedAt = Date()
        } catch {
            quota = []; quotaMessage = "无法读取 Codex 额度，请更新电脑连接程序后重试。"; quotaCheckedAt = Date()
        }
    }
    @Published var status = "未连接"
    @Published var error: String?
    @Published var queuedMessages: [CodexQueuedMessage] = []
    private let imageCache = NSCache<NSString, UIImage>()
    private var steeringMessages: Set<String> = []
    private var uploadedPaths: [String: String] = [:]
    @Published var messages: [CodexChatMessage] = []
    @Published var threadTitles: [String: String] = [:]
    func title(for thread: CodexRow) -> String { threadTitles[thread.id] ?? thread.title }
    func renameThread(_ id: String, title: String) async throws {
        let result = try await request("renameThread", ["threadId": id, "title": title])
        threadTitles[id] = result["title"] as? String ?? title
    }
    @Published var olderCursor: String?
    @Published private(set) var loadingHistory = false
    @Published private(set) var historyError: String?
    @Published private(set) var historyDeferred = false
    private var historyTask: Task<Void, Never>?
    private var historyLoadID = UUID()
    private var timelineRevision = 0
    private var selectionStartRevision = 0
    private var chatCache = CodexRecentChatCache()
    private var nextWritableCheck = Date.distantPast
    @Published var running = false
    @Published var questions: [CodexQuestionGroup] = []
    @Published var progressLabel = ""
    @Published var progressSteps: [CodexProgressStep] = []
    @Published var approvalNeeded = false
    @Published var writable = false
    @Published private(set) var desktopConnectionMessage: String?
    @Published var downloadState: CodexDownloadState?
    private var downloadTask: Task<URL, Error>?
    @Published var downloadProgress: Double?
    @Published var uploadProgress: Double?
    @Published var notice: String?
    @Published var activeTasks: [CodexRow] = []
    @Published var unreadThreads: Set<String> = []
    @Published var runningProjects: Set<String> = []
    @Published var unreadProjects: Set<String> = []
    @Published var currentModel = ""
    @Published var currentEffort = ""
    @Published var models: [CodexRow] = []
    @Published var modelEfforts: [String: [String]] = [:]
    @Published var modelDefaultEfforts: [String: String] = [:]
    @Published var taskFailure: String?
    @Published var activityError: String?
    @Published var activityLimited = false
    private var checkingActivity = false
    private static var sessions: [String: CodexConnectService] = [:]
    static func session(for device: CodexDevice) -> CodexConnectService { if let s = sessions[device.id] { return s }; let s = CodexConnectService(device: device); sessions[device.id] = s; return s }
    static func resumeAll() { for s in sessions.values { Task { await s.resumeConnection() } } }
    static func remove(_ id: String) { sessions.removeValue(forKey: id)?.disconnect() }
    private var optimistic: [String: (thread: String, text: String, bubble: CodexChatMessage, baseline: Set<String>)] = [:]
    private let chatSelection = CodexChatSelection()
    @Published private(set) var selecting = false
    @Published var device: CodexDevice
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]
    private var ready: CheckedContinuation<Void, Error>?
    private var readyTimeout: Task<Void, Never>?
    private var key: SymmetricKey?
    private var privateKey: Curve25519.KeyAgreement.PrivateKey?
    private var sid = ""
    private var sessionID = ""
    private var generation = UUID()
    private var sent = 0
    private var received = 0
    private(set) var selectedThread: String?
    private var turnID: String?
    private var showingOlder = false
    private var reconnectTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var probeGeneration: UUID?
    private var desktopRevision = 0
    private var recovery = CodexConnectionRecovery()
    private let networkMonitor = NWPathMonitor()
    private var networkRoute: String?
    private var networkAvailable = true
    private var wantsConnection = false

    init(device: CodexDevice) {
        self.device = device
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status != .unsatisfied
            let interfaces = path.availableInterfaces.filter { path.usesInterfaceType($0.type) }
            let route = interfaces.map(\.name).sorted().joined(separator: ",")
            Task { @MainActor [weak self] in await self?.networkChanged(available: available, route: route) }
        }
        networkMonitor.start(queue: DispatchQueue(label: "AstroGate.Codex.Network"))
    }
    deinit { networkMonitor.cancel(); historyTask?.cancel(); reconnectTask?.cancel(); heartbeatTask?.cancel(); receiveTask?.cancel(); sendTask?.cancel(); readyTimeout?.cancel(); socket?.cancel(with: .goingAway, reason: nil) }

    func connect() async {
        wantsConnection = true
        guard networkAvailable, !connected else { return }
        if let connectionTask {
            await connectionTask.value
            if !connected { scheduleReconnect() }
            return
        }
        reconnectTask?.cancel(); reconnectTask = nil
        let work = Task { [weak self] in
            guard let self else { return }
            await self.openConnection()
        }
        connectionTask = work
        await work.value
        connectionTask = nil
    }

    private func openConnection() async {
        guard wantsConnection, networkAvailable else { return }
        disconnectTransport(); error = nil; status = "正在连接…"
        let attempt = generation
        do {
            let account = "codex.phone.identity.v1"
            if let saved = KeychainStore.get(account: account), let data = Data(base64Encoded: saved) { privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) }
            else { let created = Curve25519.KeyAgreement.PrivateKey(); try KeychainStore.set(created.rawRepresentation.base64EncodedString(), account: account); privateKey = created }
            guard let url = URL(string: device.relay.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/phone/" + device.hostId) else { throw CodexConnectError(message: "中转地址无效") }
            sid = UUID().uuidString; sent = 0; received = 0
            let ws = URLSession.shared.webSocketTask(with: url); ws.maximumMessageSize = 1024 * 1024; socket = ws
            let current = generation
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                ready = continuation
                readyTimeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled, let self, self.generation == current else { return }
                    self.fail("连接超时。请检查电脑连接程序和中转服务是否运行。")
                }
                ws.resume()
                receiveTask = Task { [weak self] in
                    do {
                        while !Task.isCancelled {
                            let frame = try await ws.receive()
                            guard let self, self.generation == current else { return }
                            let data: Data
                            switch frame { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: continue }
                            try self.receive(data)
                        }
                    } catch { if let self, self.generation == current { self.fail("连接断开：\(error.localizedDescription)。请重连；未确认的消息不要重复发送。") } }
                }
            }
            guard generation == attempt, connected else { return }
            recovery.transportReady()
            startHeartbeat()
            if let thread = selectedThread, !showingOlder { reloadHistory(thread) }
            restoreSelectedChat()
            Task { await checkCompletions() }
        } catch { if generation == attempt { fail(error.localizedDescription) } }
    }

    private func networkChanged(available: Bool, route: String) async {
        let changed = networkAvailable != available || (networkRoute != nil && networkRoute != route)
        networkAvailable = available; networkRoute = route
        guard wantsConnection, changed else { return }
        if available { await resumeConnection() }
        else {
            reconnectTask?.cancel(); reconnectTask = nil
            fail("手机网络已断开，联网后将自动恢复。")
        }
    }

    func resumeConnection() async {
        guard wantsConnection, networkAvailable else { return }
        if !connected { await connect() }
        else if await probeConnection() { restoreSelectedChat() }
    }

    private func probeConnection() async -> Bool {
        let transport = generation
        guard connected, probeGeneration != transport else { return false }
        probeGeneration = transport
        defer { if probeGeneration == transport { probeGeneration = nil } }
        do {
            _ = try await request("ping")
            return generation == transport && !Task.isCancelled
        } catch {
            if generation == transport, !Task.isCancelled { fail("电脑连接未响应，正在自动恢复。") }
            return false
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled, let self, self.connected else { return }
                if await self.probeConnection() { Task { await self.checkCompletions() } }
            }
        }
    }
    func refreshActivity() async {
        guard connected, !checkingActivity else { return }; checkingActivity = true; defer { checkingActivity = false }
        do {
            let result = try await request("activity")
            unreadThreads = Set(result["unread"] as? [String] ?? [])
            runningProjects = Set(result["runningProjects"] as? [String] ?? [])
            unreadProjects = Set(result["unreadProjects"] as? [String] ?? [])
            activeTasks = (result["tasks"] as? [[String: Any]] ?? []).compactMap { value in
                guard let id = value["id"] as? String, let title = value["title"] as? String else { return nil }
                let state = value["awaitingApproval"] as? Bool == true ? "等待确认" : "正在运行"
                return CodexRow(id: id, title: title, path: (value["projectName"] as? String ?? "") + " · " + state)
            }
            activityLimited = result["limited"] as? Bool ?? false; activityError = nil
        } catch { activityError = "任务状态暂不可用：" + error.localizedDescription }
    }
    func disconnect() {
        chatSelection.cancel(); selecting = false
        wantsConnection = false; reconnectTask?.cancel(); reconnectTask = nil
        disconnectTransport()
    }
    private func disconnectTransport() {
        heartbeatTask?.cancel(); heartbeatTask = nil
        generation = UUID(); receiveTask?.cancel(); sendTask?.cancel(); socket?.cancel(with: .goingAway, reason: nil); socket = nil
        key = nil; activeTasks = []; connected = false; writable = false; running = false; readyTimeout?.cancel()
        desktopConnectionMessage = nil
        historyTask?.cancel(); historyLoadID = UUID(); loadingHistory = false
        let e = CodexConnectError(message: "连接已关闭")
        ready?.resume(throwing: e); ready = nil
        for c in pending.values { c.resume(throwing: e) }; pending.removeAll()
        for task in deadlines.values { task.cancel() }; deadlines.removeAll()
    }
    private func fail(_ text: String) {
        disconnectTransport(); status = wantsConnection ? "连接中断，正在自动重连…" : "未连接"; error = text
        scheduleReconnect()
    }
    private func scheduleReconnect() {
        guard wantsConnection, networkAvailable, reconnectTask == nil else { return }
        let delay = recovery.nextRetryDelay()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.wantsConnection else { return }
            self.reconnectTask = nil; await self.connect()
        }
    }
    private func enqueue(_ value: [String: Any], encrypted: Bool) {
        let before = sendTask, current = generation
        sendTask = Task { [weak self] in
            await before?.value
            guard let self, self.generation == current, !Task.isCancelled else { return }
            do {
                let frame = encrypted ? ["type": "secure", "box": try self.seal(value)] as [String: Any] : value
                guard let ws = self.socket else { throw CodexConnectError(message: "连接已关闭") }
                try await ws.send(.data(JSONSerialization.data(withJSONObject: frame)))
            } catch { if self.generation == current && !Task.isCancelled { self.fail(error.localizedDescription) } }
        }
    }
    private func aad(_ direction: String, _ sequence: Int) -> Data { Data("\(device.hostId)|\(sessionID)|\(direction)|\(sequence)".utf8) }
    private func seal(_ value: [String: Any]) throws -> [String: Any] {
        guard let key else { throw CodexConnectError(message: "尚未完成连接验证") }; sent += 1
        let box = try AES.GCM.seal(JSONSerialization.data(withJSONObject: value), using: key, authenticating: aad("c2h", sent))
        return ["seq": sent, "nonce": Data(box.nonce).base64EncodedString(), "body": (box.ciphertext + box.tag).base64EncodedString()]
    }
    private func open(_ box: [String: Any]) throws -> [String: Any] {
        guard let key, let seq = box["seq"] as? Int, seq == received + 1,
              let n = box["nonce"] as? String, let nonce = Data(base64Encoded: n), nonce.count == 12,
              let b = box["body"] as? String, let body = Data(base64Encoded: b), body.count >= 16, body.count < 900000 else { throw CodexConnectError(message: "消息校验失败，请重新连接") }
        let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: body.dropLast(16), tag: body.suffix(16))
        let data = try AES.GCM.open(sealed, using: key, authenticating: aad("h2c", seq))
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CodexConnectError(message: "消息格式无效") }
        received = seq; return value
    }
    private func receive(_ data: Data) throws {
        guard let frame = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if frame["type"] as? String == "challenge" {
            guard key == nil, let nonce = frame["nonce"] as? String, nonce.count == 43, let privateKey,
                  let hostData = Data(codexBase64URL: device.hostKey) else { throw CodexConnectError(message: "电脑身份验证失败") }
            sessionID = sid + "|" + nonce
            let shared = try privateKey.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: hostData))
            let salt = Data(SHA256.hash(data: Data((device.hostId + "|" + sessionID).utf8)))
            key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data("ifile-connect-v1".utf8), outputByteCount: 32)
            let hello = try seal(["pairToken": KeychainStore.get(account: "codex.pair." + device.id) ?? ""])
            enqueue(["type": "hello", "sid": sid, "publicKey": privateKey.publicKey.rawRepresentation.codexBase64URL, "box": hello], encrypted: false)
            return
        }
        if frame["type"] as? String == "rejected" { throw CodexConnectError(message: "配对失败或配对码已过期，请在电脑重新生成二维码。") }
        guard let box = frame["box"] as? [String: Any] else { return }
        let value = try open(box)
        if let id = value["id"] as? String, let continuation = pending.removeValue(forKey: id) {
            deadlines.removeValue(forKey: id)?.cancel()
            if let error = value["error"] as? String { continuation.resume(throwing: CodexConnectError(message: error)) }
            else { continuation.resume(returning: value["result"] as? [String: Any] ?? [:]) }
            return
        }
        switch value["event"] as? String {
        case "ready":
            guard value["hostId"] as? String == device.id, value["protocolVersion"] as? Int == 1 else { throw CodexConnectError(message: "电脑协议不兼容") }
            connected = true; status = "已连接 " + device.displayName
            KeychainStore.delete(account: "codex.pair." + device.id); readyTimeout?.cancel(); ready?.resume(); ready = nil
        case "timeline":
            guard value["threadId"] as? String == selectedThread else { return }
            timelineRevision += 1
            if !showingOlder { merge(value["messages"] as? [[String: Any]] ?? []) }
            running = value["status"] as? String == "active"; turnID = value["turnId"] as? String
            if running { notice = nil; taskFailure = nil }
            else { applyOutcome(value["outcome"] as? [String: Any]) }
            if let model = value["model"] as? String { currentModel = model }
            if let effort = value["reasoningEffort"] as? String { currentEffort = effort }
            approvalNeeded = value["awaitingApproval"] as? Bool ?? false
            questions = (value["questions"] as? [[String: Any]] ?? []).compactMap(CodexQuestionGroup.init)
            let progress = value["progress"] as? [String: Any] ?? [:]
            progressLabel = progress["label"] as? String ?? ""
            progressSteps = (progress["steps"] as? [[String: Any]] ?? []).compactMap(CodexProgressStep.init)
        case "threadRenamed":
            if let id = value["threadId"] as? String, let title = value["title"] as? String { threadTitles[id] = title }
        case "queued":
            guard value["threadId"] as? String == selectedThread else { return }
            queuedMessages = (value["messages"] as? [[String: Any]] ?? []).compactMap(CodexQueuedMessage.init).filter { !steeringMessages.contains($0.id) }
        case "history":
            guard value["threadId"] as? String == selectedThread else { return }
            if !showingOlder {
                merge(value["messages"] as? [[String: Any]] ?? [], history: true)
                olderCursor = value["nextCursor"] as? String
                if !running { applyOutcome(value["outcome"] as? [String: Any]) }
            }
        case "completed":
            if let id = value["id"] as? String { completion(id, threadID: value["threadId"] as? String, outcome: value["outcome"] as? [String: Any]) }
        case "notice":
            if let message = value["message"] as? String, message.hasPrefix("电脑通道重连中") {
                desktopDisconnected(message)
            } else { error = value["message"] as? String }
        case "desktopStatus":
            guard let thread = selectedThread, value["threadId"] as? String == thread else { return }
            if value["desktopState"] as? String == "ready" {
                restoreSelectedChat()
            } else if let message = value["message"] as? String {
                desktopDisconnected(message)
            }
        default: break
        }
    }
    private func desktopDisconnected(_ message: String) {
        desktopRevision += 1
        recovery.resetConversation()
        desktopConnectionMessage = message
        writable = false; running = false; approvalNeeded = false; questions = []; notice = nil
        if let thread = selectedThread, messages.isEmpty, !showingOlder { reloadHistory(thread) }
    }

    private func restoreSelectedChat() {
        guard let thread = selectedThread, !writable else { return }
        nextWritableCheck = .distantPast
        Task { [weak self] in
            guard let self, self.selectedThread == thread else { return }
            await self.ensureSelected(thread)
        }
    }

    private func applyWatch(_ result: [String: Any]) {
        writable = result["writable"] as? Bool == true
        desktopConnectionMessage = writable ? nil : result["message"] as? String
        if writable, error?.hasPrefix("对话连接暂未就绪") == true { error = nil }
    }

    func request(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        guard connected else { throw CodexConnectError(message: "电脑未连接，请返回项目页重连") }
        let id = UUID().uuidString
        let result: [String: Any] = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            deadlines[id] = Task { [weak self] in
                let seconds = ["ping": 5, "watch": 10, "activate": 10, "transcribe": 20][method] ?? 45
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self, let c = self.pending.removeValue(forKey: id) else { return }
                self.deadlines.removeValue(forKey: id)
                let mutation = ["send", "answer", "steerQueued", "removeQueued", "stop", "setModel", "createThread", "forkThread", "deleteThread", "renameThread"].contains(method)
                c.resume(throwing: CodexConnectError(message: method == "transcribe" ? "语音识别连接超时，请检查网络与识别电脑。" : mutation ? "操作确认超时，请先刷新原对话确认结果，避免重复提交。" : "读取超时，请稍后重试。"))
            }
            enqueue(["id": id, "method": method, "params": params], encrypted: true)
        }
        navigationCache.seed(method, params: params, result: result)
        if method == "deleteThread", let id = params["threadId"] as? String { navigationCache.remove(id) }
        if ["createThread", "forkThread", "renameThread"].contains(method) { navigationCache.invalidate() }
        // Fresh native list titles supersede phone-side immediate rename feedback.
        let rows = (result["threads"] as? [[String: Any]] ?? []) + (result["pinned"] as? [[String: Any]] ?? [])
        for row in rows {
            if let threadID = row["id"] as? String, let title = row["title"] as? String { threadTitles[threadID] = title }
        }
        return result
    }
    private func merge(_ rows: [[String: Any]], history: Bool = false) {
        var updated = messages
        for row in rows {
            guard let id = row["id"] as? String, row["role"] as? String == "user", let text = row["text"] as? String else { continue }
            for (key, p) in optimistic where p.thread == selectedThread && !p.baseline.contains(id) {
                if row["clientMessageId"] as? String == key || text == p.text || (!p.text.isEmpty && text.hasPrefix(p.text + "\n")) {
                    optimistic.removeValue(forKey: key); updated.removeAll { $0.id == key }
                }
            }
        }
        updated = CodexChatTimeline.merge(updated, rows.compactMap(CodexChatMessage.init), history: history)
        for p in optimistic.values where p.thread == selectedThread && !updated.contains(where: { $0.id == p.bubble.id }) { updated.append(p.bubble) }
        // At most 100 bubbles and 512 KB of text in the live screen.
        while updated.count > 200 || updated.reduce(0, { $0 + $1.text.utf8.count }) > 512000 { updated.removeFirst() }
        messages = updated
    }
    func select(_ threadID: String, activate: Bool = true) async {
        await chatSelection.run(threadID) { [weak self] token in
            await self?.loadSelection(threadID, activate: activate, token: token)
        }
    }
    func ensureSelected(_ threadID: String) async {
        guard !Task.isCancelled else { return }
        if selectedThread != threadID { await select(threadID); return }
        if !connected {
            if reconnectTask == nil { await connect() }
            return
        }
        guard !writable, !chatSelection.isRunning, Date() >= nextWritableCheck else { return }
        await chatSelection.run(threadID) { [weak self] token in
            await self?.watchSelection(threadID, activate: true, token: token)
        }
    }
    private func loadSelection(_ threadID: String, activate: Bool, token: UUID) async {
        func current() -> Bool { chatSelection.isCurrent(token, threadID: threadID) && !Task.isCancelled }
        guard current() else { return }
        selecting = true
        defer { if chatSelection.isCurrent(token, threadID: threadID) { selecting = false } }
        let retainVisibleMessages = selectedThread == threadID && !showingOlder
        let retainedCursor = retainVisibleMessages ? olderCursor : nil
        cacheCurrentChat()
        historyTask?.cancel(); historyLoadID = UUID(); loadingHistory = false; historyError = nil; historyDeferred = false
        taskFailure = nil; modelEfforts = [:]; modelDefaultEfforts = [:]
        recovery.resetConversation()
        writable = false
        desktopConnectionMessage = nil
        running = false; notice = nil; questions = []; queuedMessages = []; progressLabel = ""; progressSteps = []; currentModel = ""; currentEffort = ""; models = []; selectedThread = threadID; showingOlder = false; olderCursor = nil; turnID = nil; approvalNeeded = false; error = nil
        if retainVisibleMessages {
            olderCursor = retainedCursor
        } else {
            let cached = chatCache.get(threadID)
            messages = cached?.messages ?? []; olderCursor = cached?.cursor
        }
        selectionStartRevision = timelineRevision
        if !connected { await connect() }
        guard current(), connected else { return }
        // The persisted transcript can load even if the live desktop owner is unavailable.
        reloadHistory(threadID)
        await watchSelection(threadID, activate: activate, token: token)
    }

    private func watchSelection(_ threadID: String, activate: Bool, token: UUID) async {
        let transport = generation
        let desktop = desktopRevision
        func current() -> Bool {
            chatSelection.isCurrent(token, threadID: threadID) &&
                generation == transport && desktopRevision == desktop && !Task.isCancelled
        }
        nextWritableCheck = Date().addingTimeInterval(4)
        do {
            var result = try await request("watch", ["threadId": threadID])
            guard current() else { return }
            applyWatch(result)
            selecting = false
            if activate && recovery.shouldOpenConversation(desktopState: result["desktopState"] as? String, writable: writable) {
                // Opening Desktop can take seconds. Keep history and the live
                // timeline visible while waiting for the owner to become ready.
                desktopConnectionMessage = "正在打开电脑原对话…"
                _ = try await request("activate", ["threadId": threadID])
                guard current() else { return }
                for _ in 0..<3 {
                    try await Task.sleep(for: .seconds(1))
                    guard current() else { return }
                    result = try await request("watch", ["threadId": threadID])
                    guard current() else { return }
                    if result["writable"] as? Bool == true || (result["desktopState"] as? String ?? "ready") != "ready" { break }
                }
                applyWatch(result)
            }
            if writable {
                recovery.resetConversation()
                Task { await refreshModels(threadID) }
                Task { await refreshQueue(threadID) }
            }
        } catch is CancellationError {
            // Leaving or replacing a chat is not a connection failure.
        } catch {
            guard current() else { return }
            self.error = "对话连接暂未就绪：" + error.localizedDescription + "。可点“重新连接对话”重试。"
        }
    }
    private func cacheCurrentChat() {
        if let id = selectedThread, !showingOlder { chatCache.put(id, messages: messages, cursor: olderCursor) }
    }
    func reloadHistory(_ threadID: String, force: Bool = false) {
        guard selectedThread == threadID, connected, !loadingHistory else { return }
        historyTask?.cancel(); historyLoadID = UUID()
        let loadID = historyLoadID, transport = generation, revision = timelineRevision
        loadingHistory = true; historyError = nil; historyDeferred = false
        historyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            @MainActor func current() -> Bool { self.historyLoadID == loadID && self.selectedThread == threadID && self.generation == transport && !Task.isCancelled }
            defer { if current() { self.loadingHistory = false } }
            do {
                // The desktop stream supplies the newest messages quickly.
                // Avoid scanning a long disk history unless that stream is empty.
                if !force {
                    try await Task.sleep(for: .milliseconds(850))
                    guard current() else { return }
                    if self.timelineRevision > self.selectionStartRevision && !self.messages.isEmpty {
                        self.historyDeferred = true
                        self.cacheCurrentChat()
                        return
                    }
                }
                let page = try await self.request("history", ["threadId": threadID])
                guard current(), !self.showingOlder else { return }
                self.merge(page["messages"] as? [[String: Any]] ?? [], history: true)
                self.olderCursor = page["nextCursor"] as? String
                self.historyDeferred = false
                if !self.running, self.timelineRevision == revision { self.applyOutcome(page["outcome"] as? [String: Any]) }
                self.cacheCurrentChat()
            } catch {
                if current() {
                    self.historyError = self.messages.isEmpty ? "聊天记录暂未加载。" : "较早记录暂未加载。"
                    self.historyDeferred = true
                }
            }
        }
    }
    func leaveChat(_ expectedID: String? = nil) { if let expectedID, selectedThread != expectedID { return }; cacheCurrentChat(); historyTask?.cancel(); historyLoadID = UUID(); loadingHistory = false; historyError = nil; historyDeferred = false; let leaving = selectedThread; chatSelection.cancel(); selecting = false; selectedThread = nil; messages = []; queuedMessages = []; olderCursor = nil; writable = false; running = false; Task { if let leaving, selectedThread != leaving { _ = try? await request("unwatch", ["threadId": leaving]) } } }
    func older(_ threadID: String) async {
        guard let cursor = olderCursor else { return }
        showingOlder = true
        do {
            let page = try await request("history", ["threadId": threadID, "cursor": cursor])
            guard selectedThread == threadID else { return }
            // Older pages replace the viewport to keep phone memory bounded. Latest returns to live view.
            messages = []; merge(page["messages"] as? [[String: Any]] ?? [], history: true); olderCursor = page["nextCursor"] as? String
        } catch { self.error = error.localizedDescription }
    }
    func showOutgoing(_ text: String, to threadID: String, messageID: String, names: [String] = [], displayText: String? = nil) {
        guard selectedThread == threadID,
              !messages.contains(where: { !$0.provisional && ($0.id == messageID || $0.clientMessageID == messageID) }) else { return }
        let display = displayText ?? ([text] + names.map { "📎 " + $0 }).filter { !$0.isEmpty }.joined(separator: "\n")
        let bubble = CodexChatMessage(id: messageID, text: display, delivery: "正在发送…")
        let baseline = optimistic[messageID]?.baseline ?? Set(messages.map(\.id))
        optimistic[messageID] = (threadID, text.isEmpty ? "请查看附件" : text, bubble, baseline)
        if let index = messages.firstIndex(where: { $0.id == messageID }) { messages[index] = bubble }
        else { messages.append(bubble) }
    }
    func send(_ text: String, to threadID: String, messageID: String, attachments: [String] = []) async throws {
        if !running {
            let links = attachments.compactMap { uploadedPaths[$0] }.map { "📎 [" + URL(fileURLWithPath: $0).lastPathComponent + "](<" + $0 + ">)" }
            showOutgoing(text, to: threadID, messageID: messageID, displayText: ([text] + links).joined(separator: "\n"))
        }
        do {
            let result = try await request("send", ["threadId": threadID, "text": text, "messageId": messageID, "attachments": attachments])
            guard result["state"] as? String == "accepted" else { throw CodexConnectError(message: result["error"] as? String ?? "未确认送达，请刷新对话核实。") }
            if result["mode"] as? String == "queued" { dismissOutgoing(messageID); await refreshQueue(threadID) }
            else { updateDelivery(messageID, "已送达"); running = true }
            for id in attachments { uploadedPaths.removeValue(forKey: id) }
        } catch { updateDelivery(messageID, "送达待确认"); throw error }
    }
    func refreshQueue(_ threadID: String) async {
        let transport = generation
        do { let result = try await request("queued", ["threadId": threadID]); if selectedThread == threadID, generation == transport, !Task.isCancelled { queuedMessages = (result["messages"] as? [[String: Any]] ?? []).compactMap(CodexQueuedMessage.init).filter { !steeringMessages.contains($0.id) } } }
        catch { if selectedThread == threadID, generation == transport, !Task.isCancelled, !(error is CancellationError) { self.error = error.localizedDescription } }
    }
    func changeQueued(_ messageID: String, threadID: String, steer: Bool) async throws {
        if steer { steeringMessages.insert(messageID) }
        defer { steeringMessages.remove(messageID) }
        if steer, let message = queuedMessages.first(where: { $0.id == messageID }), selectedThread == threadID {
            showOutgoing(message.text, to: threadID, messageID: messageID, displayText: message.displayText)
            updateDelivery(messageID, "正在引导…")
            queuedMessages.removeAll { $0.id == messageID }
        }
        do {
            let result = try await request(steer ? "steerQueued" : "removeQueued", ["threadId": threadID, "messageId": messageID])
            guard result["state"] as? String == "accepted" else { throw CodexConnectError(message: result["error"] as? String ?? "送达待确认，请查看电脑原对话") }
            if steer { updateDelivery(messageID, "已引导，等待电脑同步") }
            await refreshQueue(threadID)
            if steer, selectedThread == threadID,
               let page = try? await request("history", ["threadId": threadID]), selectedThread == threadID {
                merge(page["messages"] as? [[String: Any]] ?? [], history: true)
            }
        } catch {
            if steer { steeringMessages.remove(messageID); updateDelivery(messageID, "引导送达待确认") }
            await refreshQueue(threadID)
            if steer, queuedMessages.contains(where: { $0.id == messageID }) { dismissOutgoing(messageID) }
            throw error
        }
    }
    private func thumbnailKey(_ path: String, threadID: String) -> String { device.hostKey + "\n" + threadID + "\n" + path }
    func previewFile(_ path: String, threadID: String) async throws -> URL {
        let key = thumbnailKey(path, threadID: threadID)
        return try await CodexPreviewCache.shared.file(for: key) {
            try await self.download(projectID: "thread:" + threadID, path: path, absolute: true, preview: true)
        }
    }
    func cachedThumbnail(_ path: String, threadID: String) -> UIImage? { imageCache.object(forKey: thumbnailKey(path, threadID: threadID) as NSString) }
    private func loadThumbnailData(_ path: String, threadID: String) async throws -> Data {
        let result = try await request("imageThumbnail", ["projectId": "thread:" + threadID, "absolutePath": path])
        guard let encoded = result["data"] as? String, let data = Data(base64Encoded: encoded), data.count <= 150000,
              CGImageSourceCreateWithData(data as CFData, nil) != nil else { throw CodexConnectError(message: "缩略图读取失败") }
        return data
    }
    func imageThumbnail(_ path: String, threadID: String) async throws -> UIImage {
        if let image = cachedThumbnail(path, threadID: threadID) { return image }
        let key = thumbnailKey(path, threadID: threadID)
        let data = try await CodexThumbnailCache.shared.data(for: key) { try await self.loadThumbnailData(path, threadID: threadID) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 240, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw CodexConnectError(message: "缩略图读取失败") }
        let image = UIImage(cgImage: cg)
        imageCache.countLimit = 36; imageCache.totalCostLimit = 8 * 1024 * 1024
        imageCache.setObject(image, forKey: key as NSString, cost: cg.bytesPerRow * cg.height)
        return image
    }
    func updateDelivery(_ id: String, _ state: String) {
        if var p = optimistic[id] { p.bubble.delivery = state; optimistic[id] = p }
        if let i = messages.firstIndex(where: { $0.id == id }) { messages[i].delivery = state }
    }
    func dismissOutgoing(_ id: String) { optimistic.removeValue(forKey: id); messages.removeAll { $0.id == id } }
    private func applyOutcome(_ outcome: [String: Any]?) {
        guard let outcome, let state = outcome["status"] as? String else { return }
        if state == "failed" {
            running = false; progressLabel = ""; progressSteps = []; approvalNeeded = false
            taskFailure = outcome["message"] as? String ?? "本轮执行失败，请查看电脑提示。"; notice = nil
        } else {
            taskFailure = nil
            if state == "interrupted" { notice = "本轮已停止" }
            if state == "completed" { notice = "Codex 处理完成" }
        }
    }
    private func completion(_ id: String, threadID: String?, outcome: [String: Any]?) {
        let state = outcome?["status"] as? String ?? "unknown"
        // Completion polls may contain older turns; only the timeline/history sets current chat status.
        CodexNotifications.shared.completed(id: id, host: device.displayName, status: state, message: outcome?["message"] as? String)
    }
    private func checkCompletions() async { if let r = try? await request("completions"), let items = r["items"] as? [[String: Any]] { for item in items { if let id = item["id"] as? String { completion(id, threadID: item["threadId"] as? String, outcome: item["outcome"] as? [String: Any]) } } } }
    func upload(_ url: URL, threadID: String) async throws -> String {
        uploadProgress = 0; defer { uploadProgress = nil }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256(), size = 0
        while let data = try file.read(upToCount: 192 * 1024), !data.isEmpty { size += data.count; guard size <= 25 * 1024 * 1024 else { throw CodexConnectError(message: "单个附件上限 25 MB") }; hash.update(data: data) }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let r = try await request("uploadBegin", ["threadId": threadID, "name": url.lastPathComponent, "size": size, "sha256": digest])
        guard let id = r["id"] as? String else { throw CodexConnectError(message: "上传初始化失败") }
        do {
            try file.seek(toOffset: 0); var offset = 0
            while let data = try file.read(upToCount: 192 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                let ack = try await request("uploadChunk", ["id": id, "offset": offset, "data": data.base64EncodedString()])
                offset += data.count
                guard ack["offset"] as? Int == offset else { throw CodexConnectError(message: "附件分块确认失败") }
                uploadProgress = Double(offset) / Double(max(1, size))
            }
            let complete = try await request("uploadFinish", ["id": id])
            if let path = complete["path"] as? String { uploadedPaths[id] = path }
            return id
        } catch { _ = try? await request("uploadCancel", ["id": id]); throw error }
    }
    func markRead(_ threadID: String) async {
        guard unreadThreads.contains(threadID) else { return }
        if (try? await request("markRead", ["threadId": threadID])) != nil { unreadThreads.remove(threadID) }
    }
    func refreshModels(_ threadID: String) async {
        let transport = generation
        do {
            let result = try await request("models", ["threadId": threadID])
            guard selectedThread == threadID, generation == transport, !Task.isCancelled else { return }
            let current = result["current"] as? [String: Any] ?? [:]
            currentModel = current["model"] as? String ?? ""; currentEffort = current["reasoningEffort"] as? String ?? ""
            models = (result["models"] as? [[String: Any]] ?? []).compactMap { m in guard let id = m["id"] as? String else { return nil }; return CodexRow(id: id, title: m["name"] as? String ?? id) }
            modelEfforts = [:]; modelDefaultEfforts = [:]
            for model in result["models"] as? [[String: Any]] ?? [] {
                guard let id = model["id"] as? String else { continue }
                modelEfforts[id] = (model["efforts"] as? [[String: Any]] ?? []).compactMap { $0["reasoningEffort"] as? String }
                modelDefaultEfforts[id] = model["defaultEffort"] as? String
            }
        } catch { if selectedThread == threadID, generation == transport, !Task.isCancelled, !(error is CancellationError) { self.error = error.localizedDescription } }
    }
    func chooseModel(_ model: String, threadID: String, effort: String? = nil) async throws {
        var params: [String: Any] = ["threadId": threadID, "model": model]
        if let effort { params["effort"] = effort }
        let result = try await request("setModel", params)
        guard selectedThread == threadID else { return }
        let current = result["current"] as? [String: Any] ?? [:]
        currentModel = current["model"] as? String ?? model; currentEffort = current["reasoningEffort"] as? String ?? ""
    }
    func stop(_ threadID: String) async { do { _ = try await request("stop", ["threadId": threadID, "turnId": turnID ?? ""]) } catch { self.error = error.localizedDescription } }
    func download(projectID: String, path: String, absolute: Bool = false, preview: Bool = false, direct: Bool = false) async throws -> URL {
        guard downloadTask == nil else { throw CodexConnectError(message: "已有文件正在下载，请等待完成或取消后重试") }
        downloadState = CodexDownloadState(name: path.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? "文件", preview: preview)
        downloadProgress = 0
        let task = Task { try await self.performDownload(projectID: projectID, path: path, absolute: absolute, preview: preview, direct: direct) }
        downloadTask = task
        defer { downloadTask = nil; downloadProgress = nil }
        do {
            let url = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            downloadState?.file = url; downloadState?.name = url.lastPathComponent; downloadState?.phase = .saved
            return url
        } catch {
            if error is CancellationError || task.isCancelled { downloadState?.phase = .cancelled; throw CancellationError() }
            downloadState?.phase = .failed; downloadState?.error = error.localizedDescription; throw error
        }
    }
    func cancelDownload() { downloadTask?.cancel(); if downloadTask != nil { downloadState?.phase = .cancelling } }
    func dismissDownload() { if downloadState?.active != true { downloadState = nil } }
    private func performDownload(projectID: String, path: String, absolute: Bool, preview: Bool, direct: Bool) async throws -> URL {
        try Task.checkCancellation()
        if direct, !ZeroTierService.shared.ready { throw CodexConnectError(message: "请先在服务 → ZeroTier 中启用网络并完成授权") }
        let info = try await request("filePrepare", ["projectId": projectID, absolute ? "absolutePath" : "relativePath": path, "direct": direct])
        guard let id = info["id"] as? String, let size = info["size"] as? Int, size >= 0, size <= 200 * 1024 * 1024,
              let name = info["name"] as? String, let expected = info["sha256"] as? String else { throw CodexConnectError(message: "文件信息无效") }
        defer { Task { _ = try? await request("fileRelease", ["fileId": id]) } }
        try Task.checkCancellation()
        downloadState?.name = name; downloadState?.total = size; downloadState?.phase = .receiving
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = try FileHandle(forWritingTo: temp); defer { try? file.close() }
        var offset = 0; var hash = SHA256()
        if direct {
            guard let route = info["direct"] as? [String: Any], let host = route["host"] as? String,
                  let port = route["port"] as? Int, let target = route["path"] as? String,
                  port > 0, port <= 65535, target.range(of: "^/[0-9a-f]{64}$", options: .regularExpression) != nil
            else { throw CodexConnectError(message: "电脑不支持 ZeroTier 下载，请更新连接程序") }
            let tunnel = try await ZeroTierService.shared.tunnel(host: host, port: UInt16(port))
            defer { tunnel.cancel() }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 600
            let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
            let url = URL(string: "http://127.0.0.1:\(tunnel.port)\(target)")!
            let (downloaded, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: downloaded) }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  (try FileManager.default.attributesOfItem(atPath: downloaded.path)[.size] as? NSNumber)?.intValue == size
            else { throw CodexConnectError(message: "直连下载失败或文件长度不符") }
            let source = try FileHandle(forReadingFrom: downloaded); defer { try? source.close() }
            while let bytes = try source.read(upToCount: 192 * 1024), !bytes.isEmpty {
                try Task.checkCancellation(); try file.write(contentsOf: bytes); hash.update(data: bytes); offset += bytes.count
            }
            downloadProgress = 1; downloadState?.received = offset
        }
        while offset < size {
            try Task.checkCancellation()
            let chunk = try await request("fileChunk", ["fileId": id, "offset": offset])
            guard chunk["offset"] as? Int == offset, let encoded = chunk["data"] as? String, let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= 192 * 1024, offset + bytes.count <= size else { throw CodexConnectError(message: "文件分块校验失败") }
            try Task.checkCancellation()
            try file.write(contentsOf: bytes); hash.update(data: bytes); offset += bytes.count; downloadProgress = Double(offset) / Double(max(1, size)); downloadState?.received = offset
        }
        try Task.checkCancellation()
        downloadState?.phase = .verifying
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw CodexConnectError(message: "文件完整性校验失败，请重新下载") }
        try file.close()
        let safeName = URL(fileURLWithPath: name).lastPathComponent
        guard !safeName.isEmpty, safeName != ".", safeName != ".." else { throw CodexConnectError(message: "文件名无效") }
        let folder = preview ? FileManager.default.temporaryDirectory.appendingPathComponent("codex-preview-" + UUID().uuidString, isDirectory: true) : LocalFileService.documentsDirectory.appendingPathComponent("Codex 下载", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var target = folder.appendingPathComponent(safeName)
        if FileManager.default.fileExists(atPath: target.path) { target = folder.appendingPathComponent(String(UUID().uuidString.prefix(8)) + "-" + safeName) }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temp, to: target)
        if !preview { NotificationCenter.default.post(name: Notification.Name("iFileDocumentsChanged"), object: nil) }
        return target
    }
}

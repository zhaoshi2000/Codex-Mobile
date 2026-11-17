import Foundation
import Combine
import Network
import zt

/// An application-owned ZeroTier node. It does not install or control a system VPN.
@MainActor
final class ZeroTierService: ObservableObject {
    static let shared = ZeroTierService()
    @Published private(set) var enabled = false
    @Published private(set) var ready = false
    @Published private(set) var status = "已关闭"
    @Published private(set) var nodeID = ""
    @Published private(set) var address = ""
    @Published var networkID: String
    private var monitor: Task<Void, Never>?
    private var initialized = false
    private var joined: UInt64?
    private var tunnels: [UUID: ZeroTierTunnel] = [:]
    private init() {
        networkID = UserDefaults.standard.string(forKey: "zerotier.network") ?? ""
        if UserDefaults.standard.bool(forKey: "zerotier.enabled") { Task { await setEnabled(true) } }
    }
    func setEnabled(_ value: Bool) async {
        monitor?.cancel(); monitor = nil
        if !value {
            tunnels.values.forEach { $0.cancel() }; tunnels = [:]
            if let joined { _ = zts_net_leave(joined) }; joined = nil
            enabled = false; ready = false; status = "正在关闭…"; address = ""
            // libzt destroys its service (including its storage path) on stop.
            // Reinitialize from the same protected directory before every restart.
            _ = zts_node_stop(); initialized = false
            UserDefaults.standard.set(false, forKey: "zerotier.enabled")
            try? await Task.sleep(for: .seconds(1))
            status = "已关闭"
            UserDefaults.standard.set(false, forKey: "zerotier.enabled"); return
        }
        let input = networkID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.count == 16, let network = UInt64(input, radix: 16), network != 0 else { status = "请输入 16 位网络 ID"; return }
        do {
            if !initialized {
                let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("ZeroTier", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                // The pinned SDK's cached root set can prevent discovery after
                // restart. Re-bootstrap roots; keep the device identity intact.
                let roots = folder.appendingPathComponent("roots")
                if FileManager.default.fileExists(atPath: roots.path) { try FileManager.default.removeItem(at: roots) }
                guard folder.path.withCString({ zts_init_from_storage($0) }) == 0 else { throw failure("无法初始化 ZeroTier 节点") }
                _ = zts_init_allow_roots_cache(0)
                initialized = true
            }
            if let joined, joined != network { _ = zts_net_leave(joined) }
            if !enabled { guard zts_node_start() == 0 else { throw failure("无法启动 ZeroTier") } }
            enabled = true; ready = false; status = "正在连接网络…"
            joined = nil; networkID = input.lowercased()
            UserDefaults.standard.set(networkID, forKey: "zerotier.network")
            UserDefaults.standard.set(true, forKey: "zerotier.enabled")
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    if self.joined == nil, zts_node_is_online() != 0, zts_net_join(network) == 0 { self.joined = network }
                    let id = zts_node_get_id(); self.nodeID = id == 0 ? "" : String(format: "%010llx", id)
                    self.ready = zts_net_transport_is_ready(network) != 0
                    var ip = [CChar](repeating: 0, count: 64)
                    self.address = zts_addr_get_str(network, UInt32(ZTS_AF_INET), &ip, 64) == 0 ? String(cString: ip) : ""
                    self.status = self.ready ? "已连接" : zts_node_is_online() != 0 ? "等待网络授权或地址分配" : "正在连接 ZeroTier…"
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
        } catch {
            _ = zts_node_stop(); initialized = false; enabled = false; ready = false
            UserDefaults.standard.set(false, forKey: "zerotier.enabled")
            status = error.localizedDescription
        }
    }
    func tunnel(host: String, port: UInt16) async throws -> ZeroTierTunnel {
        guard enabled, ready else { throw failure("请在服务中开启 ZeroTier，并等待网络授权完成") }
        var v4 = in_addr(); var v6 = in6_addr()
        guard inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1 else { throw failure("ZeroTier 直连请使用目标主机的网络 IP 地址") }
        guard tunnels.count < 16 else { throw failure("直连数量已达上限，请关闭部分服务后重试") }
        let tunnel = try await ZeroTierTunnel(host: host, port: port)
        tunnels[tunnel.id] = tunnel
        let id = tunnel.id
        tunnel.onClose = { [weak self] in Task { @MainActor in self?.tunnels.removeValue(forKey: id) } }
        return tunnel
    }
    private func failure(_ message: String) -> NSError { NSError(domain: "ZeroTier", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

/// One loopback connection forwarded through the embedded libzt socket stack.
/// System frameworks can keep using their normal TCP/TLS implementations.
final class ZeroTierTunnel: @unchecked Sendable {
    let id = UUID()
    private(set) var port: UInt16 = 0
    var onClose: (() -> Void)?
    private let listener: NWListener
    private var client: NWConnection?
    private let queue = DispatchQueue(label: "astrogate.zerotier.tunnel", qos: .userInitiated)
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var closed = false
    private var activeIO = 0
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
    init(host: String, port: UInt16) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.port = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !resumed else { return }
                switch state {
                case .ready: resumed = true; continuation.resume(returning: self.listener.port!.rawValue)
                case .failed(let error): resumed = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] client in
                guard let self, self.client == nil else { client.cancel(); return }
                self.client = client; self.listener.cancel(); client.start(queue: self.queue)
                DispatchQueue.global(qos: .userInitiated).async { self.connect(client, host: host, port: port) }
            }
            listener.start(queue: queue)
        }
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            if self?.client == nil { self?.cancel() }
        }
    }
    private func connect(_ client: NWConnection, host: String, port: UInt16) {
        let socket = zts_socket(host.contains(":") ? ZTS_AF_INET6 : ZTS_AF_INET, ZTS_SOCK_STREAM, 0)
        lock.lock(); if closed { lock.unlock(); if socket >= 0 { _ = zts_close(socket) }; return }; fd = socket; activeIO += 1; lock.unlock()
        defer { finishIO() }
        guard socket >= 0, host.withCString({ zts_connect(socket, $0, port, 10000) }) == 0 else { cancel(); return }
        _ = zts_set_send_timeout(socket, 15, 0)
        queue.async { self.receive(client, socket: socket) }
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = zts_read(socket, &buffer, buffer.count)
            if count <= 0 { break }
            let wait = DispatchSemaphore(value: 0)
            client.send(content: Data(buffer.prefix(Int(count))), completion: .contentProcessed { _ in wait.signal() })
            if wait.wait(timeout: .now() + 30) == .timedOut { break }
        }
        cancel()
    }
    private func receive(_ client: NWConnection, socket: Int32) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                guard self.beginIO() else { return }
                defer { self.finishIO() }
                if let data, !data.isEmpty {
                    let ok = data.withUnsafeBytes { bytes -> Bool in
                        var offset = 0
                        while offset < bytes.count {
                            let written = zts_write(socket, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                            if written <= 0 { return false }; offset += Int(written)
                        }; return true
                    }
                    if !ok { self.cancel(); return }
                }
                if error != nil { self.cancel() }
                else if complete { _ = zts_shutdown_wr(socket) }
                else { self.queue.async { self.receive(client, socket: socket) } }
            }
        }
    }
    func cancel() {
        lock.lock(); if closed { lock.unlock(); return }; closed = true
        if fd >= 0 { _ = zts_shutdown_rdwr(fd) }
        if activeIO == 0, fd >= 0 { _ = zts_close(fd); fd = -1 }
        lock.unlock()
        listener.cancel(); client?.cancel(); onClose?()
    }
    private func beginIO() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, fd >= 0 else { return false }; activeIO += 1; return true
    }
    private func finishIO() {
        lock.lock(); defer { lock.unlock() }; activeIO -= 1
        if closed, activeIO == 0, fd >= 0 { _ = zts_close(fd); fd = -1 }
    }
    deinit { cancel() }
}

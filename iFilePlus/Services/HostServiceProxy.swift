import Foundation
import Network

/// A page-scoped SOCKS5 proxy. Preserves the original web origin, TLS hostname,
/// cookies and WebSocket upgrades; only the selected service may be forwarded.
@MainActor final class HostServiceProxy {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "astrogate.web.proxy")
    private var clients: [UUID: Task<Void, Never>] = [:]
    private var sockets: [UUID: ProxySocket] = [:]
    private(set) var port: UInt16 = 0
    let username = "astrogate"
    let password = UUID().uuidString
    private var stopped = false

    init(url: URL, directHost: String?, service: CodexConnectService) async throws {
        if directHost != nil, !ZeroTierService.shared.ready { throw CodexConnectError(message: "请先在服务 → ZeroTier 中启用网络并完成授权") }
        guard let expectedHost = url.host, ["http", "https"].contains(url.scheme ?? "") else { throw CodexConnectError(message: "请输入 http 或 https 网页地址") }
        let expectedPort = url.port ?? (url.scheme == "https" ? 443 : 80)
        guard (1...65535).contains(expectedPort) else { throw CodexConnectError(message: "网页端口无效") }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let listener = self.listener
        port = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error): resumed = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { connection in
                Task { @MainActor [weak self] in
                    guard let self, !self.stopped, self.clients.count < 8 else { connection.cancel(); return }
                    let id = UUID(), socket = ProxySocket(connection)
                    self.sockets[id] = socket
                    self.clients[id] = Task {
                        defer { socket.close(); self.sockets.removeValue(forKey: id); self.clients.removeValue(forKey: id) }
                        do { try await self.forward(socket, expectedHost: expectedHost, port: UInt16(expectedPort), directHost: directHost, service: service) }
                        catch { socket.close() }
                    }
                }
            }
            listener.start(queue: queue)
        }
        listener.stateUpdateHandler = nil
    }
    func stop() {
        guard !stopped else { return }; stopped = true; listener.cancel()
        clients.values.forEach { $0.cancel() }; sockets.values.forEach { $0.close() }
        clients.removeAll(); sockets.removeAll()
    }
    private func forward(_ client: ProxySocket, expectedHost: String, port: UInt16, directHost: String?, service: CodexConnectService) async throws {
        // A local client must finish negotiation promptly, rather than pinning a slot.
        let timeout = Task { try? await Task.sleep(for: .seconds(15)); if !Task.isCancelled { client.close() } }
        defer { timeout.cancel() }
        let greeting = try await client.exactly(2)
        guard greeting[0] == 5, greeting[1] > 0 else { throw invalid() }
        let methods = try await client.exactly(Int(greeting[1]))
        guard methods.contains(2) else { throw invalid() }
        try await client.send(Data([5, 2]))
        let auth = try await client.exactly(2)
        guard auth[0] == 1 else { throw invalid() }
        let user = String(decoding: try await client.exactly(Int(auth[1])), as: UTF8.self)
        let passwordLength = try await client.exactly(1)[0]
        let supplied = String(decoding: try await client.exactly(Int(passwordLength)), as: UTF8.self)
        guard user == username, supplied == password else { throw invalid() }
        try await client.send(Data([1,0]))
        let request = try await client.exactly(4)
        guard request[0] == 5, request[1] == 1, request[2] == 0 else { throw invalid() }
        let host: String
        switch request[3] {
        case 1: host = try await client.exactly(4).map { String($0) }.joined(separator: ".")
        case 3:
            let length = try await client.exactly(1)[0]
            host = String(decoding: try await client.exactly(Int(length)), as: UTF8.self)
        case 4:
            let data = try await client.exactly(16)
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            _ = data.withUnsafeBytes { inet_ntop(AF_INET6, $0.baseAddress, &text, socklen_t(text.count)) }
            host = String(cString: text)
        default: throw invalid()
        }
        let bytes = try await client.exactly(2), requestedPort = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        guard host.lowercased() == expectedHost.lowercased(), requestedPort == port else { throw invalid() }
        timeout.cancel()
        if let directHost {
            let tunnel = try await ZeroTierService.shared.tunnel(host: directHost, port: port)
            defer { tunnel.cancel() }
            let remote = ProxySocket(NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: tunnel.port)!, using: .tcp))
            defer { remote.close() }
            try await client.send(Data([5,0,0,1,127,0,0,1,0,0]))
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in do { while let b = try await client.read() { try await remote.send(b) } } catch {} ; remote.close(); client.close() }
                group.addTask { @MainActor in do { while let b = try await remote.read() { try await client.send(b) } } catch {} ; remote.close(); client.close() }
                await group.waitForAll()
            }
        } else {
            let opened = try await service.request("networkOpen", ["host": "127.0.0.1", "port": Int(port)])
            guard let id = opened["id"] as? String else { throw invalid() }
            defer { Task { _ = try? await service.request("networkClose", ["id": id]) } }
            try await client.send(Data([5,0,0,1,127,0,0,1,0,0]))
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in
                    do { while let b = try await client.read() { _ = try await service.request("networkWrite", ["id": id, "data": b.base64EncodedString()]) } } catch {}
                    client.close()
                }
                group.addTask { @MainActor in
                    do {
                        while !Task.isCancelled && !client.closed {
                            let r = try await service.request("networkRead", ["id": id])
                            if let encoded = r["data"] as? String, let b = Data(base64Encoded: encoded), !b.isEmpty { try await client.send(b) }
                            else { try await Task.sleep(for: .milliseconds(80)) }
                            if r["eof"] as? Bool == true { break }
                        }
                    } catch {}
                    client.close()
                }
                await group.next(); group.cancelAll(); client.close()
            }
        }
    }
    private func invalid() -> Error { CodexConnectError(message: "网页代理请求无效") }
}

/// One reader and one writer, used concurrently; all socket state is on MainActor.
@MainActor final class ProxySocket {
    let connection: NWConnection
    private var buffer = Data()
    private(set) var closed = false
    init(_ connection: NWConnection) { self.connection = connection; connection.start(queue: .global(qos: .userInitiated)) }
    func close() { guard !closed else { return }; closed = true; connection.cancel() }
    func exactly(_ count: Int) async throws -> [UInt8] {
        while buffer.count < count {
            guard let data = try await receive() else { throw CodexConnectError(message: "服务连接已关闭") }; buffer.append(data)
        }
        let result = Array(buffer.prefix(count)); buffer.removeFirst(count); return result
    }
    func read() async throws -> Data? {
        try Task.checkCancellation()
        if !buffer.isEmpty { let data = buffer; buffer.removeAll(); return data }
        return try await receive()
    }
    private func receive() async throws -> Data? {
        guard !closed else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if complete { continuation.resume(returning: nil) }
                else { continuation.resume(returning: Data()) }
            }
        }
    }
    func send(_ data: Data) async throws {
        try Task.checkCancellation()
        guard !closed else { throw CodexConnectError(message: "服务连接已关闭") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}

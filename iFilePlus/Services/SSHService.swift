import Foundation
import Crypto
import Citadel
import NIOSSH
import NIOCore

private struct HostKeyProbeComplete: Error {}

/// Captures the SSH server key during a credential-free probe connection.
/// The UI asks the user to trust the fingerprint before real credentials are sent.
final class HostKeyCaptureDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var storedKey: NIOSSHPublicKey?

    var capturedKey: NIOSSHPublicKey? {
        lock.lock()
        defer { lock.unlock() }
        return storedKey
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        lock.lock()
        storedKey = hostKey
        lock.unlock()
        // Stop the handshake before the user-authentication stage. The placeholder
        // credentials in discoverHostKey are never offered to the server.
        validationCompletePromise.fail(HostKeyProbeComplete())
    }
}

enum SSHServiceError: LocalizedError {
    case hostKeyUnavailable
    case hostKeyChanged
    case missingPassword
    case missingPrivateKey
    case unsupportedPrivateKey
    case authenticationRejected(SSHAuthenticationMode)
    case passwordAuthenticationUnsupported
    case privateKeyAuthenticationUnsupported
    case hostBasedAuthenticationUnsupported
    case channelCreationFailed

    var errorDescription: String? {
        switch self {
        case .hostKeyUnavailable: return "无法读取 SSH 服务器主机密钥。请检查地址、端口和网络。"
        case .hostKeyChanged: return "服务器主机密钥与已保存的指纹不一致，连接已中止。"
        case .missingPassword: return "没有找到此连接保存的密码，请重新编辑连接并保存密码。"
        case .missingPrivateKey: return "此连接使用私钥认证，但没有找到已保存的私钥。请编辑连接并重新导入。"
        case .unsupportedPrivateKey: return "无法识别此私钥。当前支持未加密的 OpenSSH Ed25519/RSA 私钥，以及 PEM 格式的 ECDSA P-256/P-384/P-521 私钥。"
        case .authenticationRejected(.password):
            return "服务器未接受密码认证。请核对用户名、密码及服务器是否允许密码登录。如果服务器还要求验证码或多步认证，当前版本暂不支持。"
        case .authenticationRejected(.privateKey):
            return "服务器未接受私钥认证。请核对用户名、私钥是否已加入服务器授权列表，以及服务器是否要求额外认证步骤。"
        case .passwordAuthenticationUnsupported:
            return "服务器未提供 SSH 密码认证。请检查服务器支持的登录方式，或改用私钥认证。"
        case .privateKeyAuthenticationUnsupported:
            return "服务器未提供 SSH 私钥认证。请检查服务器支持的登录方式，或改用密码认证。"
        case .hostBasedAuthenticationUnsupported:
            return "服务器未提供当前请求的 SSH 主机认证方式。"
        case .channelCreationFailed:
            return "SSH 通道创建失败。请检查服务器 SSH 服务状态后重试。"
        }
    }
}

enum SSHService {
    static func discoverHostKey(host: String, port: Int) async throws -> String {
        let capture = HostKeyCaptureDelegate()
        // The API requires an auth method; host-key validation aborts before auth is sent.
        do {
            let probe = try await SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: .passwordBased(username: "ifileplus-probe", password: UUID().uuidString),
                hostKeyValidator: .custom(capture),
                reconnect: .never,
                algorithms: .all,
                protocolOptions: []
            )
            try? await probe.close()
        } catch {
            // The delegate intentionally stops the handshake after capturing the key.
            // Other failures are reported below if no host key was received.
        }
        guard let key = capture.capturedKey else { throw SSHServiceError.hostKeyUnavailable }
        return String(openSSHPublicKey: key)
    }

    static func fingerprint(for openSSHKey: String) throws -> String {
        let parts = openSSHKey.split(separator: " ")
        guard parts.count >= 2, let rawKey = Data(base64Encoded: String(parts[1])) else {
            throw SSHServiceError.hostKeyUnavailable
        }
        let digest = SHA256.hash(data: rawKey)
        let encoded = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(encoded)"
    }

    static func publicKey(from openSSHKey: String) throws -> NIOSSHPublicKey {
        try NIOSSHPublicKey(openSSHPublicKey: openSSHKey)
    }

    static func authenticationMethod(
        for connection: ServerConnection,
        password: String,
        privateKey: String?
    ) throws -> SSHAuthenticationMethod {
        guard connection.effectiveAuthenticationMode == .privateKey else {
            guard !password.isEmpty else { throw SSHServiceError.missingPassword }
            return .passwordBased(username: connection.username, password: password)
        }

        guard let privateKey, !privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SSHServiceError.missingPrivateKey
        }

        if let key = try? Insecure.RSA.PrivateKey(sshRsa: privateKey) {
            return .rsa(username: connection.username, privateKey: key)
        }
        if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: privateKey) {
            return .ed25519(username: connection.username, privateKey: key)
        }
        if let key = try? P256.Signing.PrivateKey(pemRepresentation: privateKey) {
            return .p256(username: connection.username, privateKey: key)
        }
        if let key = try? P384.Signing.PrivateKey(pemRepresentation: privateKey) {
            return .p384(username: connection.username, privateKey: key)
        }
        if let key = try? P521.Signing.PrivateKey(pemRepresentation: privateKey) {
            return .p521(username: connection.username, privateKey: key)
        }
        throw SSHServiceError.unsupportedPrivateKey
    }
}

/// PTY reads may end in the middle of a UTF-8 scalar. Keep only that unfinished
/// suffix so a later read can complete it without losing Chinese text.
private struct SSHUTF8StreamDecoder {
    private var pending: [UInt8] = []

    mutating func decode<Bytes: Sequence>(_ incoming: Bytes) -> String where Bytes.Element == UInt8 {
        var bytes = pending
        bytes.append(contentsOf: incoming)
        var index = 0

        while index < bytes.count {
            let first = bytes[index]
            let length: Int
            switch first {
            case 0xC2...0xDF: length = 2
            case 0xE0...0xEF: length = 3
            case 0xF0...0xF4: length = 4
            default: length = 1
            }

            if length == 1 {
                index += 1
                continue
            }

            let available = min(length, bytes.count - index)
            var validPrefix = true
            if available > 1 {
                for offset in 1..<available {
                    let byte = bytes[index + offset]
                    if !(0x80...0xBF).contains(byte)
                        || (offset == 1 && first == 0xE0 && byte < 0xA0)
                        || (offset == 1 && first == 0xED && byte > 0x9F)
                        || (offset == 1 && first == 0xF0 && byte < 0x90)
                        || (offset == 1 && first == 0xF4 && byte > 0x8F) {
                        validPrefix = false
                        break
                    }
                }
            }
            if !validPrefix {
                index += 1 // Decode the bad lead as U+FFFD; keep following bytes.
            } else if available < length {
                break
            } else {
                index += length
            }
        }

        pending = Array(bytes[index...])
        return String(decoding: bytes[..<index], as: UTF8.self)
    }

    mutating func finish() -> String {
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }
}

@MainActor
final class SSHSession {
    private(set) var client: SSHClient?
    private(set) var sftp: SFTPClient?
    private var ptyContinuation: AsyncStream<String>.Continuation?
    private var ptyTask: Task<Void, Never>?

    func connect(
        connection: ServerConnection,
        password: String,
        privateKey: String? = nil,
        enableSFTP: Bool = true
    ) async throws {
        guard let trustedLine = connection.trustedHostKey else { throw SSHServiceError.hostKeyUnavailable }
        let publicKey = try SSHService.publicKey(from: trustedLine)
        let auth = try SSHService.authenticationMethod(for: connection, password: password, privateKey: privateKey)
        let newClient: SSHClient
        do {
            newClient = try await SSHClient.connect(
                host: connection.host,
                port: connection.port,
                authenticationMethod: auth,
                hostKeyValidator: .trustedKeys([publicKey]),
                reconnect: .never,
                algorithms: .all,
                protocolOptions: []
            )
        } catch is InvalidHostKey {
            throw SSHServiceError.hostKeyChanged
        } catch let error as SSHClientError {
            switch error {
            case .allAuthenticationOptionsFailed:
                throw SSHServiceError.authenticationRejected(connection.effectiveAuthenticationMode)
            case .unsupportedPasswordAuthentication:
                throw SSHServiceError.passwordAuthenticationUnsupported
            case .unsupportedPrivateKeyAuthentication:
                throw SSHServiceError.privateKeyAuthenticationUnsupported
            case .unsupportedHostBasedAuthentication:
                throw SSHServiceError.hostBasedAuthenticationUnsupported
            case .channelCreationFailed:
                throw SSHServiceError.channelCreationFailed
            }
        } catch {
            throw error
        }
        do {
            let newSFTP = enableSFTP ? try await newClient.openSFTP() : nil
            client = newClient
            sftp = newSFTP
        } catch {
            try? await newClient.close()
            throw error
        }
    }

    func execute(_ command: String) async throws -> String {
        guard let client else { throw SSHServiceError.hostKeyUnavailable }
        let buffer = try await client.executeCommand(
            command,
            maxResponseSize: 2_000_000,
            mergeStreams: true,
            inShell: true
        )
        return String(data: Data(buffer.readableBytesView), encoding: .utf8) ?? ""
    }

    /// Starts a persistent interactive PTY shell. Output is delivered incrementally.
    func startInteractiveShell(
        onOutput: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) throws {
        guard let client else { throw SSHServiceError.hostKeyUnavailable }
        guard ptyTask == nil else { return }

        let streamPair = AsyncStream<String>.makeStream()
        ptyContinuation = streamPair.continuation
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: 100,
            terminalRowHeight: 32,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: .init([.ECHO: 1])
        )

        ptyTask = Task { [weak self] in
            defer {
                streamPair.continuation.finish()
                Task { @MainActor in self?.ptyContinuation = nil; self?.ptyTask = nil }
            }
            do {
                try await client.withPTY(request) { inbound, outbound in
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            var decoder = SSHUTF8StreamDecoder()
                            for try await event in inbound {
                                switch event {
                                case .stdout(let buffer), .stderr(let buffer):
                                    let value = decoder.decode(buffer.readableBytesView)
                                    if !value.isEmpty { onOutput(value) }
                                }
                            }
                            let remainder = decoder.finish()
                            if !remainder.isEmpty { onOutput(remainder) }
                        }
                        group.addTask {
                            for await input in streamPair.stream {
                                var buffer = ByteBufferAllocator().buffer(capacity: input.utf8.count)
                                buffer.writeString(input)
                                try await outbound.write(buffer)
                            }
                        }
                        _ = try await group.next()
                        group.cancelAll()
                    }
                }
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    func sendPTYInput(_ text: String) {
        ptyContinuation?.yield(text)
    }

    func disconnect() async {
        ptyContinuation?.finish()
        ptyContinuation = nil
        ptyTask?.cancel()
        ptyTask = nil
        if let sftp { try? await sftp.close() }
        if let client { try? await client.close() }
        sftp = nil
        client = nil
    }
}

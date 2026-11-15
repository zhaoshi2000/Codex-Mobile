import Foundation
import Network

/// Minimal passive-mode FTP client built on Network.framework.
/// Plain FTP is not encrypted; use SFTP for credentials or data on untrusted networks.
@MainActor
final class FTPClient {
    private let host: String
    private let port: Int
    private let queue = DispatchQueue(label: "com.ifileplus.ftp.network")
    private var control: NWConnection?
    private var controlBuffer = Data()
    private var isLoggedIn = false

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    func connect(username: String, password: String) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            throw FTPError.invalidPort
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        control = connection
        try await waitUntilReady(connection)

        var greeting = try await readResponse()
        if greeting.code == 120 { greeting = try await readResponse() }
        guard greeting.code == 220 else { throw FTPError.server(greeting.message) }

        let userResponse = try await sendCommand("USER \(safeArgument(username))")
        if userResponse.code == 331 {
            let passwordResponse = try await sendCommand("PASS \(safeArgument(password))")
            guard passwordResponse.code == 230 else { throw FTPError.authentication(passwordResponse.message) }
        } else if userResponse.code != 230 {
            throw FTPError.authentication(userResponse.message)
        }

        let typeResponse = try await sendCommand("TYPE I")
        guard typeResponse.code == 200 else { throw FTPError.server(typeResponse.message) }
        isLoggedIn = true
    }

    func listDirectory(_ path: String) async throws -> [RemoteFileEntry] {
        try requireLogin()
        var dataConnection = try await openPassiveDataConnection()
        let mlsd = try await sendCommand("MLSD \(safeArgument(path))")
        if mlsd.code == 125 || mlsd.code == 150 {
            let data = try await readAll(from: dataConnection)
            dataConnection.cancel()
            let final = try await readResponse()
            guard final.code == 226 || final.code == 250 else { throw FTPError.server(final.message) }
            return Self.parseMLSD(String(decoding: data, as: UTF8.self), basePath: path)
        }

        dataConnection.cancel()
        dataConnection = try await openPassiveDataConnection()
        let listResponse = try await sendCommand("LIST \(safeArgument(path))")
        guard listResponse.code == 125 || listResponse.code == 150 else {
            dataConnection.cancel()
            throw FTPError.server(listResponse.message)
        }
        let data = try await readAll(from: dataConnection)
        dataConnection.cancel()
        let final = try await readResponse()
        guard final.code == 226 || final.code == 250 else { throw FTPError.server(final.message) }
        return Self.parseLIST(String(decoding: data, as: UTF8.self), basePath: path)
    }

    func download(
        remotePath: String,
        to localURL: URL,
        progress: ((Int64, Int64?) -> Void)? = nil
    ) async throws {
        try requireLogin()
        let totalBytes = try await remoteSize(remotePath)
        let dataConnection = try await openPassiveDataConnection()
        do {
            let response = try await sendCommand("RETR \(safeArgument(remotePath))")
            guard response.code == 125 || response.code == 150 else {
                dataConnection.cancel()
                throw FTPError.server(response.message)
            }

            FileManager.default.createFile(atPath: localURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: localURL)
            var received: Int64 = 0
            do {
                while true {
                    try Task.checkCancellation()
                    let (data, complete) = try await receive(from: dataConnection)
                    if !data.isEmpty {
                        try handle.write(contentsOf: data)
                        received += Int64(data.count)
                        progress?(received, totalBytes)
                    }
                    if complete { break }
                }
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }

            dataConnection.cancel()
            let final = try await readResponse()
            guard final.code == 226 || final.code == 250 else { throw FTPError.server(final.message) }
        } catch {
            dataConnection.cancel()
            control?.cancel()
            control = nil
            isLoggedIn = false
            throw error
        }
    }

    func upload(
        localURL: URL,
        to remotePath: String,
        progress: ((Int64, Int64?) -> Void)? = nil
    ) async throws {
        try requireLogin()
        let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let totalBytes = (attributes[.size] as? NSNumber)?.int64Value
        let dataConnection = try await openPassiveDataConnection()
        do {
            let response = try await sendCommand("STOR \(safeArgument(remotePath))")
            guard response.code == 125 || response.code == 150 else {
                dataConnection.cancel()
                throw FTPError.server(response.message)
            }

            let handle = try FileHandle(forReadingFrom: localURL)
            var sent: Int64 = 0
            do {
                while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
                    try Task.checkCancellation()
                    try await send(data, on: dataConnection)
                    sent += Int64(data.count)
                    progress?(sent, totalBytes)
                }
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }

            dataConnection.cancel()
            let final = try await readResponse()
            guard final.code == 226 || final.code == 250 else { throw FTPError.server(final.message) }
        } catch {
            dataConnection.cancel()
            control?.cancel()
            control = nil
            isLoggedIn = false
            throw error
        }
    }

    private func remoteSize(_ path: String) async throws -> Int64? {
        guard let response = try? await sendCommand("SIZE \(safeArgument(path))"), response.code == 213 else { return nil }
        let value = response.message
            .split(whereSeparator: \.isWhitespace)
            .dropFirst()
            .first
            .flatMap { Int64($0) }
        return value
    }

    func deleteFile(_ path: String) async throws {
        let response = try await sendCommand("DELE \(safeArgument(path))")
        guard response.code == 250 else { throw FTPError.server(response.message) }
    }

    func deleteDirectory(_ path: String) async throws {
        let response = try await sendCommand("RMD \(safeArgument(path))")
        guard response.code == 250 else { throw FTPError.server(response.message) }
    }

    func makeDirectory(_ path: String) async throws {
        let response = try await sendCommand("MKD \(safeArgument(path))")
        guard response.code == 257 || response.code == 250 else { throw FTPError.server(response.message) }
    }

    func rename(_ oldPath: String, to newPath: String) async throws {
        let first = try await sendCommand("RNFR \(safeArgument(oldPath))")
        guard first.code == 350 else { throw FTPError.server(first.message) }
        let second = try await sendCommand("RNTO \(safeArgument(newPath))")
        guard second.code == 250 else { throw FTPError.server(second.message) }
    }

    func disconnect() async {
        if isLoggedIn { _ = try? await sendCommand("QUIT") }
        control?.cancel()
        control = nil
        controlBuffer.removeAll()
        isLoggedIn = false
    }

    // MARK: - Control channel

    private func requireLogin() throws {
        guard isLoggedIn, control != nil else { throw FTPError.notConnected }
    }

    private func safeArgument(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
    }

    private func sendCommand(_ command: String) async throws -> FTPResponse {
        guard let control else { throw FTPError.notConnected }
        try await send(Data((command + "\r\n").utf8), on: control)
        return try await readResponse()
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private func readResponse() async throws -> FTPResponse {
        let firstLine = try await readLine()
        guard firstLine.count >= 3, let code = Int(firstLine.prefix(3)) else {
            throw FTPError.invalidResponse(firstLine)
        }
        var lines = [firstLine]
        if firstLine.count >= 4, firstLine[firstLine.index(firstLine.startIndex, offsetBy: 3)] == "-" {
            let terminator = "\(code) "
            while true {
                let line = try await readLine()
                lines.append(line)
                if line.hasPrefix(terminator) { break }
            }
        }
        return FTPResponse(code: code, message: lines.joined(separator: "\n"))
    }

    private func readLine() async throws -> String {
        let crlf = Data([13, 10])
        while true {
            if let range = controlBuffer.range(of: crlf) {
                let lineData = controlBuffer.subdata(in: controlBuffer.startIndex..<range.lowerBound)
                controlBuffer.removeSubrange(controlBuffer.startIndex..<range.upperBound)
                return String(decoding: lineData, as: UTF8.self)
            }
            guard let control else { throw FTPError.notConnected }
            let (data, complete) = try await receive(from: control)
            controlBuffer.append(data)
            if complete && data.isEmpty { throw FTPError.connectionClosed }
        }
    }

    // MARK: - Passive data channel

    private func openPassiveDataConnection() async throws -> NWConnection {
        let epsv = try await sendCommand("EPSV")
        let dataPort: Int
        if epsv.code == 229, let parsed = Self.extractEPSVPort(epsv.message) {
            dataPort = parsed
        } else {
            let pasv = try await sendCommand("PASV")
            guard pasv.code == 227, let parsed = Self.extractPASVPort(pasv.message) else {
                throw FTPError.server("服务器不支持 EPSV/PASV 被动模式：\(epsv.message)")
            }
            dataPort = parsed
        }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: dataPort)) else { throw FTPError.invalidPort }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        try await waitUntilReady(connection)
        return connection
    }

    private func readAll(from connection: NWConnection) async throws -> Data {
        var result = Data()
        while true {
            let (data, complete) = try await receive(from: connection)
            if !data.isEmpty { result.append(data) }
            if complete { break }
        }
        return result
    }

    private func receive(from connection: NWConnection) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, Bool), Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (data ?? Data(), complete)) }
            }
        }
    }

    private func waitUntilReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: FTPError.connectionClosed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    // MARK: - Directory parsing

    private static func extractEPSVPort(_ message: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"\(\|\|\|(\d+)\|\)"#),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let range = Range(match.range(at: 1), in: message) else { return nil }
        return Int(message[range])
    }

    private static func extractPASVPort(_ message: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"\((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\)"#),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let p1Range = Range(match.range(at: 5), in: message),
              let p2Range = Range(match.range(at: 6), in: message),
              let p1 = Int(message[p1Range]), let p2 = Int(message[p2Range]) else { return nil }
        return p1 * 256 + p2
    }

    private static func parseMLSD(_ text: String, basePath: String) -> [RemoteFileEntry] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            guard let split = line.firstIndex(of: " ") else { return nil }
            let facts = String(line[..<split])
            let name = String(line[line.index(after: split)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != ".", name != ".." else { return nil }
            let isDirectory = facts.lowercased().contains("type=dir")
            let path = join(basePath, name)
            return RemoteFileEntry(name: name, path: path, isDirectory: isDirectory, detail: facts)
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func parseLIST(_ text: String, basePath: String) -> [RemoteFileEntry] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.lowercased().hasPrefix("total ") else { return nil }
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2 else { return nil }
            let isUnixStyle = parts[0].count >= 10 && (parts[0].first == "d" || parts[0].first == "-")
            let isDirectory: Bool
            let name: String
            if isUnixStyle, parts.count >= 9 {
                isDirectory = parts[0].first == "d"
                name = parts.dropFirst(8).joined(separator: " ")
            } else if let dirIndex = parts.firstIndex(where: { $0.uppercased() == "<DIR>" }) {
                isDirectory = true
                name = parts.dropFirst(dirIndex + 1).joined(separator: " ")
            } else if parts.count >= 4 {
                isDirectory = false
                name = parts.dropFirst(3).joined(separator: " ")
            } else {
                isDirectory = false
                name = parts.last.map(String.init) ?? ""
            }
            guard !name.isEmpty, name != ".", name != ".." else { return nil }
            return RemoteFileEntry(name: name, path: join(basePath, name), isDirectory: isDirectory, detail: line)
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func join(_ base: String, _ name: String) -> String {
        let cleanBase = base.isEmpty ? "/" : base
        if cleanBase == "/" { return "/\(name)" }
        let prefix = cleanBase.hasPrefix("/") ? "/" : ""
        return prefix + cleanBase.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/\(name)"
    }
}

private struct FTPResponse {
    let code: Int
    let message: String
}

enum FTPError: LocalizedError {
    case invalidPort
    case notConnected
    case connectionClosed
    case invalidResponse(String)
    case authentication(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidPort: return "FTP 端口无效。"
        case .notConnected: return "FTP 尚未连接。"
        case .connectionClosed: return "FTP 连接已关闭。"
        case .invalidResponse(let value): return "FTP 返回了无法识别的响应：\(value)"
        case .authentication(let value): return "FTP 登录失败：\(value)"
        case .server(let value): return "FTP 操作失败：\(value)"
        }
    }
}

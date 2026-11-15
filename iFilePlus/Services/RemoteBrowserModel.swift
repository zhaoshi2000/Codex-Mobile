import Foundation
import Combine
import Citadel
import NIOCore

@MainActor
final class RemoteBrowserModel: ObservableObject {
    @Published private(set) var entries: [RemoteFileEntry] = []
    @Published var currentPath: String
    @Published var isLoading = false
    @Published var isConnected = false
    @Published var showHostKeyPrompt = false
    @Published var pendingFingerprint = ""
    @Published var errorMessage: String?
    @Published var editorDocument: EditorDocument?
    @Published var isTransferring = false
    @Published var transferProgress: Double = 0
    @Published var transferStatus = ""

    let connection: ServerConnection
    private var activeConnection: ServerConnection
    private var password = ""
    private var privateKey: String?
    private var pendingHostKey: String?
    private var ftp: FTPClient?
    private var ssh: SSHSession?

    init(connection: ServerConnection) {
        self.connection = connection
        self.activeConnection = connection
        self.currentPath = connection.initialPath.isEmpty ? "/" : connection.initialPath
    }

    func start(password: String, privateKey: String? = nil, store: ConnectionStore) async {
        guard !isConnected, !isLoading else { return }
        self.password = password
        self.privateKey = privateKey
        if connection.type == .ftp || activeConnection.effectiveAuthenticationMode == .password {
            guard !password.isEmpty else {
                errorMessage = "没有找到保存的密码，请编辑连接并重新保存。"
                return
            }
        } else if privateKey?.isEmpty != false {
            errorMessage = "没有找到已保存的 SSH 私钥，请编辑连接并重新导入。"
            return
        }

        isLoading = true
        defer { isLoading = false }
        do {
            if connection.type == .ftp {
                let client = FTPClient(host: connection.host, port: connection.port)
                try await client.connect(username: connection.username, password: password)
                ftp = client
                isConnected = true
                try await loadDirectory(currentPath)
            } else {
                if activeConnection.trustedHostKey == nil {
                    let key = try await SSHService.discoverHostKey(host: connection.host, port: connection.port)
                    pendingHostKey = key
                    pendingFingerprint = try SSHService.fingerprint(for: key)
                    showHostKeyPrompt = true
                    return
                }
                try await connectSFTP()
                try await loadDirectory(currentPath)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func acceptHostKey(store: ConnectionStore) async {
        guard let key = pendingHostKey else { return }
        activeConnection.trustedHostKey = key
        store.update(activeConnection)
        showHostKeyPrompt = false
        isLoading = true
        defer { isLoading = false }
        do {
            try await connectSFTP()
            try await loadDirectory(currentPath)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelHostKeyPrompt() {
        pendingHostKey = nil
        pendingFingerprint = ""
        showHostKeyPrompt = false
    }

    func refresh() async {
        do { try await loadDirectory(currentPath) }
        catch { errorMessage = error.localizedDescription }
    }

    func open(_ entry: RemoteFileEntry) async {
        if entry.isDirectory {
            do { try await loadDirectory(entry.path) }
            catch { errorMessage = error.localizedDescription }
            return
        }
        let ext = URL(fileURLWithPath: entry.name).pathExtension.lowercased()
        guard LocalFileService.textExtensions.contains(ext) || ext.isEmpty else {
            errorMessage = "当前版本暂时只支持在线编辑文本文件。可以先下载其他类型文件。"
            return
        }
        do {
            let content = try await readText(at: entry.path)
            editorDocument = EditorDocument(title: entry.name, initialText: content) { [weak self] newText in
                guard let self else { return }
                try await self.writeText(newText, to: entry.path)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func goUp() async {
        guard currentPath != "/", !currentPath.isEmpty else { return }
        let parent = URL(fileURLWithPath: currentPath).deletingLastPathComponent().path
        do { try await loadDirectory(parent.isEmpty ? "/" : parent) }
        catch { errorMessage = error.localizedDescription }
    }

    func createFolder(named name: String) async {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let path = join(currentPath, clean)
        do {
            if let ftp { try await ftp.makeDirectory(path) }
            else if let sftp = ssh?.sftp { try await sftp.createDirectory(atPath: path) }
            try await loadDirectory(currentPath)
        } catch { errorMessage = error.localizedDescription }
    }

    func rename(_ entry: RemoteFileEntry, to newName: String) async {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let newPath = join(currentPath, clean)
        do {
            if let ftp { try await ftp.rename(entry.path, to: newPath) }
            else if let sftp = ssh?.sftp { try await sftp.rename(at: entry.path, to: newPath) }
            try await loadDirectory(currentPath)
        } catch { errorMessage = error.localizedDescription }
    }

    func delete(_ entry: RemoteFileEntry) async {
        do {
            if let ftp {
                if entry.isDirectory { try await ftp.deleteDirectory(entry.path) }
                else { try await ftp.deleteFile(entry.path) }
            } else if let sftp = ssh?.sftp {
                if entry.isDirectory { try await sftp.rmdir(at: entry.path) }
                else { try await sftp.remove(at: entry.path) }
            }
            try await loadDirectory(currentPath)
        } catch { errorMessage = error.localizedDescription }
    }

    func upload(_ localURL: URL) async {
        guard !isTransferring else { return }
        guard !entries.contains(where: { $0.name == localURL.lastPathComponent }) else {
            errorMessage = "远程目录已存在同名项目：\(localURL.lastPathComponent)"
            return
        }
        let remotePath = join(currentPath, localURL.lastPathComponent)
        beginTransfer("正在上传：\(localURL.lastPathComponent)")
        defer { endTransfer() }
        do {
            if let ftp {
                try await ftp.upload(localURL: localURL, to: remotePath) { [weak self] current, total in
                    self?.updateTransfer(current: current, total: total)
                }
            } else if let sftp = ssh?.sftp {
                let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
                let total = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                let source = try FileHandle(forReadingFrom: localURL)
                let remote = try await sftp.openFile(filePath: remotePath, flags: [.write, .create, .truncate])
                var offset: UInt64 = 0
                do {
                    while let data = try source.read(upToCount: 64 * 1024), !data.isEmpty {
                        try Task.checkCancellation()
                        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                        buffer.writeBytes(data)
                        try await remote.write(buffer, at: offset)
                        offset += UInt64(data.count)
                        updateTransfer(current: Int64(offset), total: total)
                    }
                    try source.close()
                    try await remote.close()
                } catch {
                    try? source.close()
                    try? await remote.close()
                    throw error
                }
            }
            try await loadDirectory(currentPath)
            transferStatus = "上传完成"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func download(_ entry: RemoteFileEntry) async {
        guard !entry.isDirectory, !isTransferring else { return }
        let destination = uniqueLocalURL(for: entry.name)
        beginTransfer("正在下载：\(entry.name)")
        defer { endTransfer() }
        do {
            if let ftp {
                try await ftp.download(remotePath: entry.path, to: destination) { [weak self] current, total in
                    self?.updateTransfer(current: current, total: total)
                }
            } else if let sftp = ssh?.sftp {
                let data = try await sftp.withFile(filePath: entry.path, flags: .read) { file in
                    let buffer = try await file.readAll()
                    return Data(buffer.readableBytesView)
                }
                try data.write(to: destination, options: .atomic)
                updateTransfer(current: Int64(data.count), total: Int64(data.count))
            }
            transferStatus = "已下载到本地 Documents：\(destination.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createTextFile(named name: String) async {
        var clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if URL(fileURLWithPath: clean).pathExtension.isEmpty { clean += ".txt" }
        guard !entries.contains(where: { $0.name == clean }) else {
            errorMessage = "远程目录已存在同名项目：\(clean)"
            return
        }
        let path = join(currentPath, clean)
        do {
            if let ftp {
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
                defer { try? FileManager.default.removeItem(at: temp) }
                try Data().write(to: temp)
                try await ftp.upload(localURL: temp, to: path)
            } else if let sftp = ssh?.sftp {
                try await sftp.withFile(filePath: path, flags: [.write, .create, .truncate]) { _ in }
            }
            try await loadDirectory(currentPath)
        } catch { errorMessage = error.localizedDescription }
    }

    func disconnect() async {
        await ftp?.disconnect()
        await ssh?.disconnect()
        ftp = nil
        ssh = nil
        isConnected = false
        entries = []
        isTransferring = false
    }

    private func beginTransfer(_ message: String) {
        isTransferring = true
        transferProgress = 0
        transferStatus = message
    }

    private func updateTransfer(current: Int64, total: Int64?) {
        if let total, total > 0 {
            transferProgress = min(1, Double(current) / Double(total))
            transferStatus = "\(ByteCountFormatter.string(fromByteCount: current, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
        } else {
            transferProgress = 0
            transferStatus = "已传输 \(ByteCountFormatter.string(fromByteCount: current, countStyle: .file))"
        }
    }

    private func endTransfer() {
        isTransferring = false
        transferProgress = 1
    }

    private func connectSFTP() async throws {
        let session = SSHSession()
        try await session.connect(
            connection: activeConnection,
            password: password,
            privateKey: privateKey
        )
        ssh = session
        isConnected = true
    }

    private func loadDirectory(_ path: String) async throws {
        isLoading = true
        defer { isLoading = false }
        let normalized = path.isEmpty ? "/" : path
        if let ftp {
            entries = try await ftp.listDirectory(normalized)
        } else if let sftp = ssh?.sftp {
            let raw = try await sftp.listDirectory(atPath: normalized)
            entries = raw.flatMap(\.components).compactMap { item in
                let name = item.filename
                guard name != ".", name != ".." else { return nil }
                let isDirectory = item.longname.first == "d"
                return RemoteFileEntry(name: name, path: Self.join(normalized, name), isDirectory: isDirectory, detail: item.longname)
            }.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        } else {
            throw FTPError.notConnected
        }
        currentPath = normalized
    }

    private func readText(at path: String) async throws -> String {
        if let ftp {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
            defer { try? FileManager.default.removeItem(at: temp) }
            try await ftp.download(remotePath: path, to: temp)
            return try LocalFileService.readText(temp)
        }
        guard let sftp = ssh?.sftp else { throw FTPError.notConnected }
        return try await sftp.withFile(filePath: path, flags: .read) { file in
            let buffer = try await file.readAll()
            let data = Data(buffer.readableBytesView)
            return LocalFileService.decodeText(data)
        }
    }

    private func writeText(_ text: String, to path: String) async throws {
        if let ftp {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
            defer { try? FileManager.default.removeItem(at: temp) }
            try Data(text.utf8).write(to: temp, options: .atomic)
            try await ftp.upload(localURL: temp, to: path)
            return
        }
        guard let sftp = ssh?.sftp else { throw FTPError.notConnected }
        try await sftp.withFile(filePath: path, flags: [.write, .create, .truncate]) { file in
            try await file.write(ByteBuffer(string: text), at: 0)
        }
    }

    private func uniqueLocalURL(for name: String) -> URL {
        let root = LocalFileService.documentsDirectory
        var candidate = root.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var index = 1
        repeat {
            let fileName = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            candidate = root.appendingPathComponent(fileName)
            index += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }

    private func join(_ base: String, _ name: String) -> String { Self.join(base, name) }

    private static func join(_ base: String, _ name: String) -> String {
        let cleanBase = base.isEmpty ? "/" : base
        if cleanBase == "/" { return "/\(name)" }
        let prefix = cleanBase.hasPrefix("/") ? "/" : ""
        return prefix + cleanBase.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/\(name)"
    }
}

/// A text view is not a terminal emulator. Remove terminal protocol bytes while
/// retaining the visible text, including escape sequences split across PTY reads.
private struct TerminalOutputSanitizer {
    private enum State {
        case text, escape, escapeIntermediate, csi, osc, oscEscape
        case controlString, controlStringEscape
    }

    private var state: State = .text
    private var sequenceLength = 0
    private var csiParameters = ""
    private var carriageReturnPending = false

    mutating func consume(_ chunk: String, onto text: String) -> String {
        var rendered = text
        for scalar in chunk.unicodeScalars {
            let value = scalar.value
            switch state {
            case .text:
                switch value {
                case 0x1B: state = .escape
                case 0x9B: beginCSI() // 8-bit CSI
                case 0x9D: beginOSC() // 8-bit OSC
                case 0x90, 0x98, 0x9E, 0x9F: beginControlString()
                case 0x0D: carriageReturnPending = true
                case 0x0A:
                    carriageReturnPending = false
                    rendered.append("\n")
                case 0x08:
                    if !carriageReturnPending && rendered.last != "\n" && !rendered.isEmpty {
                        rendered.removeLast()
                    }
                case 0x09: appendVisible(scalar, to: &rendered)
                case 0x20...0x7E, 0xA0...0x10FFFF:
                    appendVisible(scalar, to: &rendered)
                default: break // Other C0/C1 controls and DEL are not text.
                }

            case .escape:
                switch value {
                case 0x5B: beginCSI() // ESC [
                case 0x5D: beginOSC() // ESC ]
                case 0x50, 0x58, 0x5E, 0x5F: beginControlString()
                case 0x28...0x2B, 0x4E, 0x4F: state = .escapeIntermediate
                case 0x44, 0x45: // Index / next line.
                    carriageReturnPending = false
                    rendered.append("\n")
                    state = .text
                case 0x1B: break
                default: state = .text
                }

            case .escapeIntermediate:
                state = .text

            case .csi:
                if value == 0x1B {
                    state = .escape
                } else if (0x40...0x7E).contains(value) {
                    applyCSI(final: value, to: &rendered)
                    state = .text
                } else if (0x20...0x3F).contains(value) {
                    sequenceLength += 1
                    if csiParameters.count < 64 { csiParameters.unicodeScalars.append(scalar) }
                    if sequenceLength > 1024 { state = .text }
                } else {
                    state = .text
                }

            case .osc:
                if value == 0x07 || value == 0x9C {
                    state = .text
                } else if value == 0x1B {
                    state = .oscEscape
                } else {
                    sequenceLength += 1
                    if sequenceLength > 8192 { state = .text }
                }

            case .oscEscape:
                state = value == 0x5C || value == 0x9C ? .text : .osc

            case .controlString:
                if value == 0x9C {
                    state = .text
                } else if value == 0x1B {
                    state = .controlStringEscape
                } else {
                    sequenceLength += 1
                    if sequenceLength > 8192 { state = .text }
                }

            case .controlStringEscape:
                state = value == 0x5C || value == 0x9C ? .text : .controlString
            }
        }
        return rendered
    }

    private mutating func beginCSI() {
        state = .csi
        sequenceLength = 0
        csiParameters = ""
    }

    private mutating func beginOSC() {
        state = .osc
        sequenceLength = 0
    }

    private mutating func beginControlString() {
        state = .controlString
        sequenceLength = 0
    }

    private mutating func appendVisible(_ scalar: Unicode.Scalar, to text: inout String) {
        if carriageReturnPending {
            clearCurrentLine(&text)
            carriageReturnPending = false
        }
        text.unicodeScalars.append(scalar)
    }

    private mutating func applyCSI(final: UInt32, to text: inout String) {
        switch final {
        case 0x4B: // Erase in line. Text is always appended at the visible end.
            if carriageReturnPending || csiParameters == "2" {
                clearCurrentLine(&text)
                carriageReturnPending = false
            }
        case 0x47: // Cursor horizontal absolute: column one is a redraw.
            if csiParameters.isEmpty || csiParameters == "1" {
                carriageReturnPending = true
            }
        default: break // Styling and other cursor controls have no text equivalent.
        }
    }

    private func clearCurrentLine(_ text: inout String) {
        if let newline = text.lastIndex(of: "\n") {
            text.removeSubrange(text.index(after: newline)..<text.endIndex)
        } else {
            text.removeAll()
        }
    }
}

@MainActor
final class SSHTerminalModel: ObservableObject {
    @Published var output = "AstroGate SSH Terminal\n正在建立交互式 PTY 会话……\n\n"
    @Published var command = ""
    @Published var isConnected = false
    @Published var isRunning = false
    @Published var showHostKeyPrompt = false
    @Published var pendingFingerprint = ""
    @Published var errorMessage: String?
    @Published private(set) var history: [String] = []

    private var connection: ServerConnection
    private var password = ""
    private var privateKey: String?
    private var pendingHostKey: String?
    private var session: SSHSession?
    private var terminalSanitizer = TerminalOutputSanitizer()

    init(connection: ServerConnection) { self.connection = connection }

    func start(password: String, privateKey: String? = nil, store: ConnectionStore) async {
        guard !isConnected, !isRunning else { return }
        self.password = password
        self.privateKey = privateKey
        if connection.effectiveAuthenticationMode == .password && password.isEmpty {
            errorMessage = "没有找到保存的密码，请编辑连接并重新保存。"
            return
        }
        if connection.effectiveAuthenticationMode == .privateKey && privateKey?.isEmpty != false {
            errorMessage = "没有找到已保存的 SSH 私钥，请编辑连接并重新导入。"
            return
        }
        isRunning = true
        defer { isRunning = false }
        do {
            if connection.trustedHostKey == nil {
                let key = try await SSHService.discoverHostKey(host: connection.host, port: connection.port)
                pendingHostKey = key
                pendingFingerprint = try SSHService.fingerprint(for: key)
                showHostKeyPrompt = true
                return
            }
            try await connect()
        } catch { errorMessage = error.localizedDescription }
    }

    func acceptHostKey(store: ConnectionStore) async {
        guard let key = pendingHostKey else { return }
        connection.trustedHostKey = key
        store.update(connection)
        showHostKeyPrompt = false
        isRunning = true
        defer { isRunning = false }
        do { try await connect() }
        catch { errorMessage = error.localizedDescription }
    }

    func cancelHostKeyPrompt() {
        pendingHostKey = nil
        pendingFingerprint = ""
        showHostKeyPrompt = false
    }

    func runCommand() async {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let session, isConnected else { return }
        command = ""
        history.append(value)
        session.sendPTYInput(value + "\r")
    }

    func sendControl(_ key: String) {
        guard let session, isConnected else { return }
        switch key {
        case "CTRL-C": session.sendPTYInput("\u{03}")
        case "CTRL-D": session.sendPTYInput("\u{04}")
        case "TAB": session.sendPTYInput("\t")
        case "ESC": session.sendPTYInput("\u{1B}")
        case "UP": session.sendPTYInput("\u{1B}[A")
        case "DOWN": session.sendPTYInput("\u{1B}[B")
        case "LEFT": session.sendPTYInput("\u{1B}[D")
        case "RIGHT": session.sendPTYInput("\u{1B}[C")
        default: break
        }
    }

    func disconnect() async {
        await session?.disconnect()
        session = nil
        isConnected = false
        appendStatus("\n[连接已断开]\n")
    }

    private func connect() async throws {
        let newSession = SSHSession()
        try await newSession.connect(
            connection: connection,
            password: password,
            privateKey: privateKey,
            enableSFTP: false
        )
        session = newSession
        isConnected = true
        appendStatus("已连接：\(connection.host):\(connection.port)\n")
        terminalSanitizer = TerminalOutputSanitizer()
        try newSession.startInteractiveShell(
            onOutput: { [weak self] value in
                Task { @MainActor in self?.appendOutput(value) }
            },
            onError: { [weak self] message in
                Task { @MainActor in
                    self?.appendStatus("\n[PTY 错误] \(message)\n")
                    self?.isConnected = false
                }
            }
        )
    }

    private func appendOutput(_ value: String) {
        output = terminalSanitizer.consume(value, onto: output)
        trimOutput()
    }

    private func appendStatus(_ value: String) {
        output += value
        trimOutput()
    }

    private func trimOutput() {
        // Keep the view model bounded during long-running sessions.
        if output.count > 200_000 { output = String(output.suffix(160_000)) }
    }
}

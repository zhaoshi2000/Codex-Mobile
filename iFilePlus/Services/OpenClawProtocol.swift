import Foundation

enum OpenClawWireError: LocalizedError {
    case invalidConfiguration, invalidResponse, remote(String)
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "请检查 OpenClaw 命令路径、容器名称和会话名称。"
        case .invalidResponse: return "OpenClaw 没有返回有效数据，请检查服务器上的命令路径、登录用户和 Gateway 状态。"
        case .remote(let text): return String(text.prefix(600))
        }
    }
}

// Native chat calls the server's own CLI over an authenticated SSH channel.
// The CLI keeps its Gateway credentials on the server.
enum OpenClawProtocol {
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    static func command(executable: String, container: String, method: String, params: [String: Any]) throws -> String {
        guard ["sessions.list", "chat.history", "chat.send", "chat.abort"].contains(method),
              !executable.isEmpty, executable.utf8.count < 1024, !executable.contains("\0"), !executable.contains("\n"),
              container.isEmpty || container.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", options: .regularExpression) != nil else { throw OpenClawWireError.invalidConfiguration }
        let data = try JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])
        guard data.count < 128000 else { throw OpenClawWireError.invalidConfiguration }
        let prefix = container.isEmpty ? quote(executable) : "docker exec " + quote(container) + " " + quote(executable)
        return "export PATH=\"$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:$PATH\"; NO_COLOR=1 " + prefix + " gateway call " + quote(method) + " --params " + quote(String(decoding: data, as: UTF8.self)) + " --json --timeout 15000"
    }
    static func decode(_ output: String) throws -> [String: Any] {
        let data = Data(output.utf8)
        guard data.count <= 2_000_000 else { throw OpenClawWireError.invalidResponse }
        // Some CLI versions print a doctor warning before the JSON result.
        let lines = output.components(separatedBy: "\n")
        for offset in lines.indices.prefix(80) where lines[offset].trimmingCharacters(in: .whitespaces).hasPrefix("{") {
            let candidate = lines[offset...].joined(separator: "\n")
            guard let value = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)) as? [String: Any] else { continue }
            if let error = value["error"] as? [String: Any] { throw OpenClawWireError.remote(error["message"] as? String ?? "OpenClaw 请求失败") }
            if let error = value["error"] as? String { throw OpenClawWireError.remote(error) }
            if value["ok"] as? Bool == false { throw OpenClawWireError.remote(value["message"] as? String ?? "OpenClaw 拒绝了请求") }
            return value["payload"] as? [String: Any] ?? value["result"] as? [String: Any] ?? value
        }
        if output.contains("not found") || output.contains("No such file") { throw OpenClawWireError.remote("找不到 OpenClaw 命令，请在编辑连接中填写服务器的可执行文件路径或 Docker 容器名称。") }
        throw OpenClawWireError.invalidResponse
    }
    static func text(_ message: [String: Any]) -> String {
        if let text = message["content"] as? String { return String(text.prefix(16000)) }
        if let content = message["content"] as? [[String: Any]] { return String(content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n").prefix(16000)) }
        return String((message["text"] as? String ?? "").prefix(16000))
    }
}

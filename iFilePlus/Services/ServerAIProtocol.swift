import Foundation

struct ServerAIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct ServerAITool: Identifiable {
    let id: String
    let name: String
    let arguments: String
    var command: String? {
        guard name == "run_command", let data = arguments.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let command = value["command"] as? String, !command.isEmpty, command.utf8.count <= 16000, !command.contains("\0") else { return nil }
        return command
    }
    var reason: String {
        guard let data = arguments.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return String((value["reason"] as? String ?? "").prefix(2000))
    }
    var json: [String: Any] { ["id": id, "type": "function", "function": ["name": name, "arguments": arguments]] }
}
struct ServerAIStream {
    var text = ""
    var calls: [Int: (id: String, name: String, arguments: String)] = [:]
    var finished = false
    mutating func consume(_ line: String) throws {
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { finished = true; return }
        guard let data = payload.data(using: .utf8), let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ServerAIError(message: "中转站返回的数据格式无效") }
        if obj["error"] != nil { throw ServerAIError(message: "中转站返回流式错误，请检查模型与额度") }
        guard let choice = (obj["choices"] as? [[String: Any]])?.first else { return }
        if let reason = choice["finish_reason"] as? String {
            guard ["stop", "tool_calls"].contains(reason) else { throw ServerAIError(message: "模型输出未完成（" + reason + "），未执行任何新命令") }
            finished = true
        }
        let delta = choice["delta"] as? [String: Any] ?? [:]
        text += delta["content"] as? String ?? ""
        for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
            guard let index = call["index"] as? Int, (0..<4).contains(index) else { throw ServerAIError(message: "一次最多支持 4 个命令") }
            var value = calls[index] ?? ("", "", "")
            if let id = call["id"] as? String { value.id += id }
            if let f = call["function"] as? [String: Any] { value.name += f["name"] as? String ?? ""; value.arguments += f["arguments"] as? String ?? "" }
            guard value.arguments.utf8.count <= 32000, value.id.count <= 200, value.name.count <= 100 else { throw ServerAIError(message: "命令内容过长") }; calls[index] = value
        }
        guard text.utf8.count <= 128000 else { throw ServerAIError(message: "回复过长，请缩小请求范围") }
    }
    func tools() throws -> [ServerAITool] {
        guard finished else { throw ServerAIError(message: "输出连接提前中断，未执行命令，请重试") }
        let result = calls.keys.sorted().map { index in let v = calls[index]!; return ServerAITool(id: v.id, name: v.name, arguments: v.arguments) }
        guard result.allSatisfy({ !$0.id.isEmpty && $0.command != nil }), Set(result.map(\.id)).count == result.count else { throw ServerAIError(message: "模型返回了不支持或不完整的命令") }
        return result
    }
}
enum ServerAIProtocol {
    static func modelsEndpoint(_ input: String) throws -> URL {
        let chat = try endpoint(input)
        return chat.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("models")
    }
    static func modelIDs(_ data: Data) throws -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]], object["error"] == nil else {
            throw ServerAIError(message: "中转站未返回有效模型列表，可手动填写模型名称")
        }
        let ids = rows.compactMap { $0["id"] as? String }.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count < 200 && !$0.contains(where: { $0.isNewline })
        }
        let models = Set(ids).sorted()
        guard !models.isEmpty else { throw ServerAIError(message: "此 API Key 暂无可用模型，可检查权限或手动填写模型名称") }
        return models
    }
    static func endpoint(_ input: String) throws -> URL {
        guard var c = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)), c.scheme == "https", c.host != nil, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil else { throw ServerAIError(message: "请填写 HTTPS 中转地址，不要把密钥放在网址里") }
        var path = c.path; while path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty { path = "/v1" }
        if !path.hasSuffix("/chat/completions") { path += "/chat/completions" }; c.path = path
        guard let url = c.url else { throw ServerAIError(message: "地址无效") }; return url
    }
    static let tool: [String: Any] = ["type": "function", "function": ["name": "run_command", "description": "Propose one non-interactive Linux SSH shell command. The user must review and approve it before execution. Do not read secrets or unrelated personal data.", "parameters": ["type": "object", "properties": ["command": ["type": "string"], "reason": ["type": "string"]], "required": ["command", "reason"], "additionalProperties": false]]]
    static func shellCommand(_ command: String, marker: String) -> String {
        // A separate shell preserves newlines and shell syntax as one argument.
        "if command -v timeout >/dev/null 2>&1; then timeout 600 sh -lc " + OpenClawProtocol.quote(command) + "; else sh -lc " + OpenClawProtocol.quote(command) + "; fi; ifile_rc=$?; printf '\\n" + marker + "%s\\n' \"$ifile_rc\""
    }
    static func redact(_ text: String, secrets: [String]) -> String {
        var value = text
        for secret in secrets where !secret.isEmpty { value = value.replacingOccurrences(of: secret, with: "[密钥已隐藏]") }
        if let re = try? NSRegularExpression(pattern: "-----BEGIN [^-]*PRIVATE KEY-----[\\s\\S]*?-----END [^-]*PRIVATE KEY-----|(?i:Bearer)\\s+[^\\s]+|sk-[A-Za-z0-9_-]{12,}") { value = re.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "[密钥已隐藏]") }
        return value
    }
}

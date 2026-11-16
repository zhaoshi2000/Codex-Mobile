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
    // Shared with Android: bundle.mjs copies this shell program into app assets.
    // Positional arguments keep server settings and chat text out of shell syntax.
    static let launcher = #"""
    exe=$1; container=$2; target=$3; shift 3
    if [ -n "$container" ]; then
      NO_COLOR=1 docker exec "$container" "$exe" "$@"
      exit $?
    fi
    find_cli() {
      for p in "$1/.local/openclaw/bin/openclaw" "$1/.local/bin/openclaw" "$1/.npm-global/bin/openclaw" "$1"/.local/node-*/bin/openclaw "$1"/.nvm/versions/node/*/bin/openclaw; do
        if [ -x "$p" ]; then printf '%s\n' "$p"; return; fi
      done
    }
    if [ -z "$target" ] && [ "$exe" = openclaw ] && ! command -v openclaw >/dev/null 2>&1; then
      found=$(find_cli "$HOME")
      if [ -n "$found" ]; then exe=$found
      elif [ "$(id -u)" = 0 ]; then
        count=0
        for home in /home/*; do
          if [ -d "$home/.openclaw" ] && [ -n "$(find_cli "$home")" ]; then
            candidate=$(stat -c %U "$home" 2>/dev/null)
            if [ -n "$candidate" ]; then target=$candidate; count=$((count+1)); fi
          fi
        done
        if [ "$count" -gt 1 ]; then echo '发现多个 OpenClaw 安装用户，请在编辑服务中指定运行用户。' >&2; exit 2; fi
      fi
    fi
    invoke='export PATH="$HOME/.local/openclaw/bin:$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:$PATH"
    for d in "$HOME"/.local/node-*/bin "$HOME"/.nvm/versions/node/*/bin; do [ ! -d "$d" ] || PATH="$d:$PATH"; done
    export PATH NO_COLOR=1
    cd "$HOME" || exit 1
    if ! command -v "$1" >/dev/null 2>&1; then echo "找不到 OpenClaw 命令，请检查运行用户、命令路径或容器名称。" >&2; exit 127; fi
    exec "$@"'
    if [ -n "$target" ] && [ "$target" != "$(id -un)" ]; then
      home=$(getent passwd "$target" | cut -d: -f6)
      if [ -z "$home" ]; then echo 'OpenClaw 运行用户不存在。' >&2; exit 2; fi
      if [ "$(id -u)" = 0 ]; then
        exec runuser -u "$target" -- env HOME="$home" sh -c "$invoke" sh "$exe" "$@"
      else
        exec sudo -n -u "$target" -H sh -c "$invoke" sh "$exe" "$@"
      fi
    fi
    exec sh -c "$invoke" sh "$exe" "$@"
    """#

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    static func command(executable: String, container: String, user: String = "", method: String, params: [String: Any]) throws -> String {
        guard ["sessions.list", "chat.history", "chat.send", "chat.abort"].contains(method),
              !executable.isEmpty, executable.utf8.count < 1024, !executable.contains("\0"), !executable.contains("\n"),
              container.isEmpty || container.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", options: .regularExpression) != nil,
              user.isEmpty || user.range(of: "^[a-zA-Z_][a-zA-Z0-9_-]{0,63}$", options: .regularExpression) != nil else { throw OpenClawWireError.invalidConfiguration }
        let data = try JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])
        guard data.count < 128000 else { throw OpenClawWireError.invalidConfiguration }
        let args = [executable, container, user, "gateway", "call", method, "--params", String(decoding: data, as: UTF8.self), "--json", "--timeout", "15000"]
        // Citadel drops command output on a nonzero exit. Preserve it in a framed result instead.
        return "sh -c " + quote(launcher) + " sh " + args.map(quote).joined(separator: " ") + " 2>&1; code=$?; printf '\\n__ASTROGATE_OC_EXIT__:%s\\n' \"$code\""
    }
    static func decode(_ raw: String) throws -> [String: Any] {
        var output = raw
        if let marker = output.range(of: "\n__ASTROGATE_OC_EXIT__:", options: .backwards) {
            let code = Int(output[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines))
            output = String(output[..<marker.lowerBound])
            guard code == 0 else { throw OpenClawWireError.remote("OpenClaw 命令失败（退出码 \(code ?? -1)）：\n" + String(output.suffix(500))) }
        }
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

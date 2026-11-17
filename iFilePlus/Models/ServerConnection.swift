import Foundation

// MARK: - Remote connection models

enum ConnectionType: String, CaseIterable, Codable, Identifiable {
    case ftp = "FTP"
    case sftp = "SFTP"
    case ssh = "SSH"

    var id: String { rawValue }

    var defaultPort: Int {
        switch self {
        case .ftp: return 21
        case .sftp, .ssh: return 22
        }
    }

    var subtitle: String {
        switch self {
        case .ftp: return "文件传输协议（未加密）"
        case .sftp: return "SSH 加密文件传输"
        case .ssh: return "远程命令终端"
        }
    }

    var icon: String {
        switch self {
        case .ftp: return "arrow.up.arrow.down.circle.fill"
        case .sftp: return "lock.icloud.fill"
        case .ssh: return "terminal.fill"
        }
    }
}

enum SSHAuthenticationMode: String, CaseIterable, Codable, Identifiable {
    case password
    case privateKey

    var id: String { rawValue }
    var title: String { self == .password ? "密码认证" : "SSH 私钥认证" }
}

struct ServerConnection: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var type: ConnectionType
    var host: String
    var port: Int
    var username: String
    var initialPath: String = "/"
    /// OpenSSH public-key line accepted by the user (TOFU pinning).
    var trustedHostKey: String? = nil
    /// Optional for backwards compatibility with 0.1.0 saved configurations.
    var authenticationMode: SSHAuthenticationMode? = nil
    var useZeroTier: Bool? = nil

    var effectiveAuthenticationMode: SSHAuthenticationMode {
        authenticationMode ?? .password
    }

    var openClawAlias: String? = nil
    var openClawExecutable: String? = nil
    var openClawContainer: String? = nil
    var openClawSession: String? = nil
    var openClawUser: String? = nil
    var chatAlias: String { let value = openClawAlias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""; return value.isEmpty ? "OC" : value }

    var address: String { "\(host):\(port)" }
}

struct RemoteFileEntry: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let isDirectory: Bool
    var detail: String = ""
}

struct EditorDocument: Identifiable {
    let id = UUID()
    let title: String
    let initialText: String
    let onSave: (String) async throws -> Void
}

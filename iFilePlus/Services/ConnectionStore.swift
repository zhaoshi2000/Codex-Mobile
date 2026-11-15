import Foundation
import Combine

@MainActor
final class ConnectionStore: ObservableObject {
    @Published private(set) var connections: [ServerConnection] = []
    private let storageKey = "ifileplus.connections.v1"

    init() { load() }

    func upsert(
        _ connection: ServerConnection,
        password: String,
        privateKey: String? = nil
    ) throws {
        let passwordAccount = credentialAccount(connection.id, suffix: "password")
        let keyAccount = credentialAccount(connection.id, suffix: "privateKey")

        if !password.isEmpty {
            try KeychainStore.set(password, account: passwordAccount)
        } else if connection.type != .ftp && connection.effectiveAuthenticationMode == .privateKey {
            KeychainStore.delete(account: passwordAccount)
        }

        if connection.effectiveAuthenticationMode == .privateKey {
            guard let privateKey, !privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConnectionStoreError.missingPrivateKey
            }
            try KeychainStore.set(privateKey, account: keyAccount)
        } else {
            KeychainStore.delete(account: keyAccount)
        }

        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
        } else {
            connections.append(connection)
        }
        persist()
    }

    func update(_ connection: ServerConnection) {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[index] = connection
        persist()
    }

    func delete(_ connection: ServerConnection) {
        connections.removeAll { $0.id == connection.id }
        KeychainStore.delete(account: credentialAccount(connection.id, suffix: "password"))
        KeychainStore.delete(account: credentialAccount(connection.id, suffix: "privateKey"))
        persist()
    }

    func password(for id: UUID) -> String? {
        KeychainStore.get(account: credentialAccount(id, suffix: "password"))
    }

    func privateKey(for id: UUID) -> String? {
        KeychainStore.get(account: credentialAccount(id, suffix: "privateKey"))
    }

    private func credentialAccount(_ id: UUID, suffix: String) -> String {
        "\(id.uuidString).\(suffix)"
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ServerConnection].self, from: data) else { return }
        connections = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

enum ConnectionStoreError: LocalizedError {
    case missingPrivateKey

    var errorDescription: String? {
        switch self {
        case .missingPrivateKey: return "请选择并导入 SSH 私钥文件。"
        }
    }
}

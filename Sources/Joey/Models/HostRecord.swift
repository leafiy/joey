import Foundation

/// One remote host configuration (CONTEXT.md: Host Record). The SFTP engine
/// and the rsync command line are both generated from this single record.
///
/// Secrets (password, key passphrase) are stored in plaintext inside
/// settings.json per leafiy-ui ADR-0002 (no Keychain); the Settings UI carries
/// the privacy notice.
struct HostRecord: Identifiable, Codable, Equatable {
    enum AuthMethod: String, Codable {
        case password
        case privateKey
    }

    var id = UUID()
    var name: String = ""
    var host: String = ""
    var port: Int = 22
    var username: String = ""
    var authMethod: AuthMethod = .password
    var password: String = ""
    var privateKeyPath: String = ""
    var keyPassphrase: String = ""
    /// Optional fixed landing directory used whenever this host is activated.
    /// Empty preserves the Last Browsed Directory behavior.
    var defaultDirectory: String = ""
    /// CONTEXT.md: Last Browsed Directory — the panel-drop landing point,
    /// updated on every browse.
    var lastBrowsedDirectory: String = ""

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, authMethod, password
        case privateKeyPath, keyPassphrase, defaultDirectory, lastBrowsedDirectory
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        host = (try? container.decode(String.self, forKey: .host)) ?? ""
        port = (try? container.decode(Int.self, forKey: .port)) ?? 22
        username = (try? container.decode(String.self, forKey: .username)) ?? ""
        authMethod =
            (try? container.decode(AuthMethod.self, forKey: .authMethod)) ?? .password
        password = (try? container.decode(String.self, forKey: .password)) ?? ""
        privateKeyPath =
            (try? container.decode(String.self, forKey: .privateKeyPath)) ?? ""
        keyPassphrase =
            (try? container.decode(String.self, forKey: .keyPassphrase)) ?? ""
        defaultDirectory =
            (try? container.decode(String.self, forKey: .defaultDirectory)) ?? ""
        lastBrowsedDirectory =
            (try? container.decode(String.self, forKey: .lastBrowsedDirectory)) ?? ""
    }

    var browserStartDirectory: String? {
        if !defaultDirectory.isEmpty { return defaultDirectory }
        if !lastBrowsedDirectory.isEmpty { return lastBrowsedDirectory }
        return nil
    }

    var displayName: String {
        if !name.isEmpty { return name }
        if !host.isEmpty { return username.isEmpty ? host : "\(username)@\(host)" }
        return "Untitled Host"
    }

    var isComplete: Bool {
        !host.isEmpty && !username.isEmpty
            && (authMethod == .password ? !password.isEmpty : !privateKeyPath.isEmpty)
    }

    var engineAuth: SSHConnection.Auth {
        switch authMethod {
        case .password:
            return .password(password)
        case .privateKey:
            return .privateKey(
                path: (privateKeyPath as NSString).expandingTildeInPath,
                passphrase: keyPassphrase.isEmpty ? nil : keyPassphrase)
        }
    }

    /// rsync is key-auth only (docs/research/rsync-detect-and-install.md §4).
    var supportsRsync: Bool { authMethod == .privateKey && !privateKeyPath.isEmpty }

    /// True when `other` reaches the same endpoint with the same credentials —
    /// the fields whose change invalidates a cached connection. Display name
    /// and Last Browsed Directory don't count.
    func connectionEquals(_ other: HostRecord) -> Bool {
        host == other.host && port == other.port && username == other.username
            && authMethod == other.authMethod && password == other.password
            && privateKeyPath == other.privateKeyPath && keyPassphrase == other.keyPassphrase
    }
}

/// A favorite remote drop target (ticket 08): one Host Record + one remote
/// directory. At most `Favorite.maxCount` may be configured.
struct Favorite: Identifiable, Codable, Equatable {
    static let maxCount = 3

    var id = UUID()
    var hostID: UUID
    var directory: String

    func displayLabel(hosts: [HostRecord]) -> String {
        let hostName = hosts.first(where: { $0.id == hostID })?.displayName ?? "?"
        return "\(hostName) : \(directory)"
    }
}

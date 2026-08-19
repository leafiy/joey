import CLibssh
import Foundation

/// Errors surfaced by the spike engine. `cancelled` is the clean-cancel path;
/// everything else is a hard failure carrying the underlying libssh detail.
enum SpikeError: Error, CustomStringConvertible {
    case session(String)
    case auth(String)
    case hostKey(String)
    case sftp(String)
    case io(String)
    case cancelled

    var description: String {
        switch self {
        case .session(let m): return "session: \(m)"
        case .auth(let m): return "auth: \(m)"
        case .hostKey(let m): return "host key: \(m)"
        case .sftp(let m): return "sftp: \(m)"
        case .io(let m): return "io: \(m)"
        case .cancelled: return "cancelled"
        }
    }
}

struct DirEntry {
    let name: String
    let isDirectory: Bool
    let size: UInt64
}

/// Thin synchronous wrapper around libssh — the API shape that graduates into
/// `SSHEngine` if the spike passes (ticket 03). One instance = one connection.
///
/// Progress closures receive `(bytesDone, bytesTotal)` and return `true` to
/// continue; returning `false` cancels the transfer, which throws
/// `SpikeError.cancelled` and leaves the session usable for further calls.
final class SpikeSSHEngine {
    enum Auth {
        case password(String)
        case privateKey(path: String, passphrase: String?)
    }

    enum HostKeyPolicy {
        case strict
        case acceptUnknown
    }

    let host: String
    let port: UInt32
    let user: String

    private var session: ssh_session?
    private var sftp: sftp_session?
    // Server-reported request-size ceilings (limits@openssh.com); refined on
    // first SFTP use, defaults are safe for any server.
    private(set) var maxWriteChunk = 128 << 10
    private(set) var maxReadChunk = 128 << 10

    init(host: String, port: UInt32, user: String) {
        self.host = host
        self.port = port
        self.user = user
    }

    deinit { disconnect() }

    // MARK: - Connection

    /// Connects, verifies the host key against known_hosts, authenticates.
    /// Returns the server key fingerprint ("SHA256:…").
    @discardableResult
    func connect(auth: Auth, hostKeyPolicy: HostKeyPolicy) throws -> String {
        precondition(session == nil, "already connected")
        guard let s = ssh_new() else { throw SpikeError.session("ssh_new failed") }
        session = s
        do {
            try setOption(s, SSH_OPTIONS_HOST, host)
            try setOption(s, SSH_OPTIONS_USER, user)
            var portValue = port
            _ = ssh_options_set(s, SSH_OPTIONS_PORT, &portValue)
            var timeout: CLong = 15
            _ = ssh_options_set(s, SSH_OPTIONS_TIMEOUT, &timeout)
            // The spike's flags are authoritative; don't let ~/.ssh/config rewrite them.
            var processConfig: CBool = false
            _ = ssh_options_set(s, SSH_OPTIONS_PROCESS_CONFIG, &processConfig)

            guard ssh_connect(s) == SSH_OK else {
                throw SpikeError.session("connect to \(host):\(port) failed: \(lastError(s))")
            }
            let fingerprint = try verifyHostKey(s, policy: hostKeyPolicy)
            try authenticate(s, auth)
            return fingerprint
        } catch {
            disconnect()
            throw error
        }
    }

    func disconnect() {
        if let sf = sftp {
            sftp_free(sf)
            sftp = nil
        }
        if let s = session {
            if ssh_is_connected(s) == 1 { ssh_disconnect(s) }
            ssh_free(s)
            session = nil
        }
    }

    private func setOption(_ s: ssh_session, _ option: ssh_options_e, _ value: String) throws {
        let rc = value.withCString { ssh_options_set(s, option, $0) }
        guard rc == SSH_OK else {
            throw SpikeError.session("ssh_options_set(\(option.rawValue)) failed: \(lastError(s))")
        }
    }

    private func verifyHostKey(_ s: ssh_session, policy: HostKeyPolicy) throws -> String {
        let fingerprint = try hostKeyFingerprint(s)
        let state = ssh_session_is_known_server(s)
        switch state {
        case SSH_KNOWN_HOSTS_OK:
            break
        case SSH_KNOWN_HOSTS_NOT_FOUND, SSH_KNOWN_HOSTS_UNKNOWN:
            guard policy == .acceptUnknown else {
                throw SpikeError.hostKey(
                    "\(host) not in known_hosts (\(fingerprint)); rerun with --accept-unknown to trust it")
            }
            guard ssh_session_update_known_hosts(s) == SSH_OK else {
                throw SpikeError.hostKey("failed to update known_hosts: \(lastError(s))")
            }
        case SSH_KNOWN_HOSTS_CHANGED:
            throw SpikeError.hostKey(
                "HOST KEY CHANGED for \(host) (\(fingerprint)) — possible MITM; fix ~/.ssh/known_hosts manually")
        case SSH_KNOWN_HOSTS_OTHER:
            throw SpikeError.hostKey(
                "host key type for \(host) changed (\(fingerprint)); fix ~/.ssh/known_hosts manually")
        default:
            throw SpikeError.hostKey("known_hosts check failed: \(lastError(s))")
        }
        return fingerprint
    }

    private func hostKeyFingerprint(_ s: ssh_session) throws -> String {
        var pubkey: ssh_key?
        guard ssh_get_server_publickey(s, &pubkey) == SSH_OK, pubkey != nil else {
            throw SpikeError.hostKey("cannot read server public key: \(lastError(s))")
        }
        defer { ssh_key_free(pubkey) }
        var hash: UnsafeMutablePointer<UInt8>?
        var hashLen = 0
        guard ssh_get_publickey_hash(pubkey, SSH_PUBLICKEY_HASH_SHA256, &hash, &hashLen) == 0 else {
            throw SpikeError.hostKey("cannot hash server public key")
        }
        defer { ssh_clean_pubkey_hash(&hash) }
        guard let cstr = ssh_get_fingerprint_hash(SSH_PUBLICKEY_HASH_SHA256, hash, hashLen) else {
            throw SpikeError.hostKey("cannot format server key fingerprint")
        }
        defer { ssh_string_free_char(cstr) }
        return String(cString: cstr)
    }

    private func authenticate(_ s: ssh_session, _ auth: Auth) throws {
        switch auth {
        case .password(let password):
            let rc = password.withCString { ssh_userauth_password(s, nil, $0) }
            guard rc == SSH_AUTH_SUCCESS.rawValue else {
                throw SpikeError.auth("password auth failed (rc=\(rc)): \(lastError(s))")
            }
        case .privateKey(let path, let passphrase):
            var key: ssh_key?
            let importRC: Int32
            if let passphrase {
                importRC = ssh_pki_import_privkey_file(path, passphrase, nil, nil, &key)
            } else {
                importRC = ssh_pki_import_privkey_file(path, nil, nil, nil, &key)
            }
            guard importRC == SSH_OK, key != nil else {
                let hint = importRC == SSH_EOF
                    ? "file not found or unreadable"
                    : "wrong passphrase or unsupported format?"
                throw SpikeError.auth("cannot import private key \(path) (\(hint))")
            }
            defer { ssh_key_free(key) }
            let rc = ssh_userauth_publickey(s, nil, key)
            guard rc == SSH_AUTH_SUCCESS.rawValue else {
                throw SpikeError.auth("public key auth failed (rc=\(rc)): \(lastError(s))")
            }
        }
    }

    // MARK: - SFTP

    private func sftpSession() throws -> sftp_session {
        if let sftp { return sftp }
        guard let s = session else { throw SpikeError.session("not connected") }
        guard let sf = sftp_new(s) else {
            throw SpikeError.sftp("sftp_new failed: \(lastError(s))")
        }
        guard sftp_init(sf) == SSH_OK else {
            let message = "sftp_init failed (code \(sftp_get_error(sf))): \(lastError(s))"
            sftp_free(sf)
            throw SpikeError.sftp(message)
        }
        sftp = sf
        if let limits = sftp_limits(sf) {
            defer { sftp_limits_free(limits) }
            let cap: UInt64 = 4 << 20
            if limits.pointee.max_write_length > 0 {
                maxWriteChunk = Int(min(limits.pointee.max_write_length, cap))
            }
            if limits.pointee.max_read_length > 0 {
                maxReadChunk = Int(min(limits.pointee.max_read_length, cap))
            }
        }
        return sf
    }

    /// Reads the whole directory (no truncation — loops until EOF).
    /// Includes "." and ".." entries as reported by the server.
    func listDirectory(_ path: String) throws -> [DirEntry] {
        let sf = try sftpSession()
        guard let dir = sftp_opendir(sf, path) else { throw sftpError("opendir \(path)") }
        defer { sftp_closedir(dir) }
        var entries: [DirEntry] = []
        while let attrs = sftp_readdir(sf, dir) {
            defer { sftp_attributes_free(attrs) }
            guard let cname = attrs.pointee.name else { continue }
            entries.append(DirEntry(
                name: String(cString: cname),
                isDirectory: attrs.pointee.type == UInt8(SSH_FILEXFER_TYPE_DIRECTORY),
                size: attrs.pointee.size))
        }
        guard sftp_dir_eof(dir) == 1 else { throw sftpError("readdir \(path) stopped before EOF") }
        return entries
    }

    func stat(_ remotePath: String) throws -> UInt64 {
        let sf = try sftpSession()
        guard let attrs = sftp_stat(sf, remotePath) else { throw sftpError("stat \(remotePath)") }
        defer { sftp_attributes_free(attrs) }
        return attrs.pointee.size
    }

    func removeFile(_ remotePath: String) throws {
        let sf = try sftpSession()
        guard sftp_unlink(sf, remotePath) == SSH_OK else { throw sftpError("unlink \(remotePath)") }
    }

    func upload(
        localPath: String,
        remotePath: String,
        chunkSize: Int,
        progress: (UInt64, UInt64) -> Bool
    ) throws {
        let sf = try sftpSession()
        let chunk = max(1, min(chunkSize, maxWriteChunk))
        guard let local = FileHandle(forReadingAtPath: localPath) else {
            throw SpikeError.io("cannot open local file \(localPath)")
        }
        defer { try? local.close() }
        let total = localFileSize(localPath) ?? 0

        guard let remote = sftp_open(sf, remotePath, O_WRONLY | O_CREAT | O_TRUNC, 0o644) else {
            throw sftpError("open \(remotePath) for writing")
        }
        var remoteClosed = false
        defer { if !remoteClosed { sftp_close(remote) } }

        var sent: UInt64 = 0
        while true {
            guard progress(sent, total) else { throw SpikeError.cancelled }
            let data = try autoreleasepool { try local.read(upToCount: chunk) }
            guard let data, !data.isEmpty else { break }
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < raw.count {
                    let n = sftp_write(remote, raw.baseAddress! + offset, raw.count - offset)
                    guard n > 0 else { throw sftpError("write to \(remotePath) at byte \(sent)") }
                    offset += n
                }
            }
            sent += UInt64(data.count)
        }
        _ = progress(sent, total)
        remoteClosed = true
        guard sftp_close(remote) == SSH_OK else { throw sftpError("close \(remotePath)") }
    }

    func download(
        remotePath: String,
        localPath: String,
        chunkSize: Int,
        progress: (UInt64, UInt64) -> Bool
    ) throws {
        let sf = try sftpSession()
        let chunk = max(1, min(chunkSize, maxReadChunk))
        let total = try stat(remotePath)

        guard let remote = sftp_open(sf, remotePath, O_RDONLY, 0) else {
            throw sftpError("open \(remotePath) for reading")
        }
        var remoteClosed = false
        defer { if !remoteClosed { sftp_close(remote) } }

        guard FileManager.default.createFile(atPath: localPath, contents: nil),
              let local = FileHandle(forWritingAtPath: localPath) else {
            throw SpikeError.io("cannot create local file \(localPath)")
        }
        defer { try? local.close() }

        var buffer = [UInt8](repeating: 0, count: chunk)
        var received: UInt64 = 0
        while true {
            guard progress(received, total) else { throw SpikeError.cancelled }
            let n = buffer.withUnsafeMutableBytes { sftp_read(remote, $0.baseAddress!, chunk) }
            if n == 0 { break }
            guard n > 0 else { throw sftpError("read from \(remotePath) at byte \(received)") }
            try buffer.withUnsafeBytes { raw in
                try autoreleasepool {
                    try local.write(contentsOf: Data(bytes: raw.baseAddress!, count: n))
                }
            }
            received += UInt64(n)
        }
        _ = progress(received, total)
        remoteClosed = true
        sftp_close(remote)
    }

    // MARK: - Errors

    private func lastError(_ s: ssh_session) -> String {
        String(cString: ssh_get_error(UnsafeMutableRawPointer(s)))
    }

    private func sftpError(_ what: String) -> SpikeError {
        var detail = ""
        if let sf = sftp { detail += " (sftp code \(sftp_get_error(sf)))" }
        if let s = session { detail += ": \(lastError(s))" }
        return .sftp(what + detail)
    }
}

func localFileSize(_ path: String) -> UInt64? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
    return (attrs[.size] as? NSNumber)?.uint64Value
}

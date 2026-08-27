import CLibssh
import Foundation

/// Errors surfaced by the SSH engine. `cancelled` is the clean-cancel path;
/// everything else is a hard failure carrying the underlying libssh detail.
enum SSHEngineError: Error, CustomStringConvertible {
    case session(String)
    case auth(String)
    case hostKey(String)
    case sftp(String)
    case io(String)
    case exec(String)
    case cancelled

    var description: String {
        switch self {
        case .session(let m): return "session: \(m)"
        case .auth(let m): return "auth: \(m)"
        case .hostKey(let m): return "host key: \(m)"
        case .sftp(let m): return "sftp: \(m)"
        case .io(let m): return "io: \(m)"
        case .exec(let m): return "exec: \(m)"
        case .cancelled: return "cancelled"
        }
    }
}

struct RemoteEntry: Identifiable, Hashable {
    let name: String
    let isDirectory: Bool
    let size: UInt64
    let modificationTime: UInt64

    init(
        name: String,
        isDirectory: Bool,
        size: UInt64,
        modificationTime: UInt64 = 0
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modificationTime = modificationTime
    }

    var id: String { name }
}

/// Result of running a remote command over an exec channel.
struct ExecResult {
    let exitStatus: Int32
    let stdout: String
    let stderr: String
}

/// Thin synchronous wrapper around libssh, graduated from the ticket-03 spike.
/// One instance = one connection. Not thread-safe — callers serialize access
/// (see `HostSession`).
///
/// Progress closures receive `(bytesDone, bytesTotal)` and return `true` to
/// continue; returning `false` cancels the transfer, which throws
/// `SSHEngineError.cancelled` and leaves the session usable for further calls.
final class SSHConnection {
    enum Auth {
        case password(String)
        case privateKey(path: String, passphrase: String?)
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

    var isConnected: Bool {
        guard let s = session else { return false }
        return ssh_is_connected(s) == 1
    }

    // MARK: - Connection

    /// Connects, verifies the host key against known_hosts (accept-new
    /// policy: unknown hosts are trusted and recorded, changed keys are a
    /// hard error), authenticates. Returns the server key fingerprint.
    @discardableResult
    func connect(auth: Auth) throws -> String {
        precondition(session == nil, "already connected")
        guard let s = ssh_new() else { throw SSHEngineError.session("ssh_new failed") }
        session = s
        do {
            try setOption(s, SSH_OPTIONS_HOST, host)
            try setOption(s, SSH_OPTIONS_USER, user)
            var portValue = port
            _ = ssh_options_set(s, SSH_OPTIONS_PORT, &portValue)
            var timeout: CLong = 15
            _ = ssh_options_set(s, SSH_OPTIONS_TIMEOUT, &timeout)
            // The Host Record is authoritative; don't let ~/.ssh/config rewrite it.
            var processConfig: CBool = false
            _ = ssh_options_set(s, SSH_OPTIONS_PROCESS_CONFIG, &processConfig)
            // Nagle batches the small SFTP request packets, adding a delay on
            // top of every round-trip the window is already paying for.
            var noDelay: CInt = 1
            _ = ssh_options_set(s, SSH_OPTIONS_NODELAY, &noDelay)
            // libssh's default order leads with chacha20-poly1305, which is
            // software-only; AES-GCM rides AES-NI on every Mac and every
            // server worth talking to. This is libssh's own set, reordered —
            // nothing is dropped, so no server becomes unreachable.
            let ciphers = "aes128-gcm@openssh.com,aes256-gcm@openssh.com,"
                + "chacha20-poly1305@openssh.com,aes128-ctr,aes192-ctr,aes256-ctr"
            _ = ciphers.withCString { ssh_options_set(s, SSH_OPTIONS_CIPHERS_C_S, $0) }
            _ = ciphers.withCString { ssh_options_set(s, SSH_OPTIONS_CIPHERS_S_C, $0) }

            guard ssh_connect(s) == SSH_OK else {
                throw SSHEngineError.session("connect to \(host):\(port) failed: \(lastError(s))")
            }
            configureSocketKeepalive(s)
            let fingerprint = try verifyHostKey(s)
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
            throw SSHEngineError.session("ssh_options_set(\(option.rawValue)) failed: \(lastError(s))")
        }
    }

    private func verifyHostKey(_ s: ssh_session) throws -> String {
        let fingerprint = try hostKeyFingerprint(s)
        switch ssh_session_is_known_server(s) {
        case SSH_KNOWN_HOSTS_OK:
            break
        case SSH_KNOWN_HOSTS_NOT_FOUND, SSH_KNOWN_HOSTS_UNKNOWN:
            guard ssh_session_update_known_hosts(s) == SSH_OK else {
                throw SSHEngineError.hostKey("failed to update known_hosts: \(lastError(s))")
            }
        case SSH_KNOWN_HOSTS_CHANGED:
            throw SSHEngineError.hostKey(
                "HOST KEY CHANGED for \(host) (\(fingerprint)) — possible MITM; fix ~/.ssh/known_hosts manually")
        case SSH_KNOWN_HOSTS_OTHER:
            throw SSHEngineError.hostKey(
                "host key type for \(host) changed (\(fingerprint)); fix ~/.ssh/known_hosts manually")
        default:
            throw SSHEngineError.hostKey("known_hosts check failed: \(lastError(s))")
        }
        return fingerprint
    }

    private func hostKeyFingerprint(_ s: ssh_session) throws -> String {
        var pubkey: ssh_key?
        guard ssh_get_server_publickey(s, &pubkey) == SSH_OK, pubkey != nil else {
            throw SSHEngineError.hostKey("cannot read server public key: \(lastError(s))")
        }
        defer { ssh_key_free(pubkey) }
        var hash: UnsafeMutablePointer<UInt8>?
        var hashLen = 0
        guard ssh_get_publickey_hash(pubkey, SSH_PUBLICKEY_HASH_SHA256, &hash, &hashLen) == 0 else {
            throw SSHEngineError.hostKey("cannot hash server public key")
        }
        defer { ssh_clean_pubkey_hash(&hash) }
        guard let cstr = ssh_get_fingerprint_hash(SSH_PUBLICKEY_HASH_SHA256, hash, hashLen) else {
            throw SSHEngineError.hostKey("cannot format server key fingerprint")
        }
        defer { ssh_string_free_char(cstr) }
        return String(cString: cstr)
    }

    private func authenticate(_ s: ssh_session, _ auth: Auth) throws {
        switch auth {
        case .password(let password):
            let rc = password.withCString { ssh_userauth_password(s, nil, $0) }
            guard rc == SSH_AUTH_SUCCESS.rawValue else {
                throw SSHEngineError.auth("password auth failed (rc=\(rc)): \(lastError(s))")
            }
        case .privateKey(let path, let passphrase):
            var key: ssh_key?
            let importRC: Int32
            if let passphrase, !passphrase.isEmpty {
                importRC = ssh_pki_import_privkey_file(path, passphrase, nil, nil, &key)
            } else {
                importRC = ssh_pki_import_privkey_file(path, nil, nil, nil, &key)
            }
            guard importRC == SSH_OK, key != nil else {
                let hint = importRC == SSH_EOF
                    ? "file not found or unreadable"
                    : "wrong passphrase or unsupported format?"
                throw SSHEngineError.auth("cannot import private key \(path) (\(hint))")
            }
            defer { ssh_key_free(key) }
            let rc = ssh_userauth_publickey(s, nil, key)
            guard rc == SSH_AUTH_SUCCESS.rawValue else {
                throw SSHEngineError.auth("public key auth failed (rc=\(rc)): \(lastError(s))")
            }
        }
    }

    // MARK: - SFTP

    private func sftpSession() throws -> sftp_session {
        if let sftp { return sftp }
        guard let s = session else { throw SSHEngineError.session("not connected") }
        guard let sf = sftp_new(s) else {
            throw SSHEngineError.sftp("sftp_new failed: \(lastError(s))")
        }
        guard sftp_init(sf) == SSH_OK else {
            let message = "sftp_init failed (code \(sftp_get_error(sf))): \(lastError(s))"
            sftp_free(sf)
            throw SSHEngineError.sftp(message)
        }
        sftp = sf
        if let limits = sftp_limits(sf) {
            defer { sftp_limits_free(limits) }
            // Pipelining multiplies this by the window depth, so it is capped
            // far below the old 4 MB: a server advertising a huge chunk would
            // otherwise put hundreds of megabytes in flight.
            let cap: UInt64 = 1 << 20
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
    /// "." and ".." are dropped; everything else is returned as reported.
    func listDirectory(_ path: String) throws -> [RemoteEntry] {
        let sf = try sftpSession()
        guard let dir = sftp_opendir(sf, path) else { throw sftpError("opendir \(path)") }
        defer { sftp_closedir(dir) }
        var entries: [RemoteEntry] = []
        while let attrs = sftp_readdir(sf, dir) {
            defer { sftp_attributes_free(attrs) }
            guard let cname = attrs.pointee.name else { continue }
            let name = String(cString: cname)
            if name == "." || name == ".." { continue }
            entries.append(RemoteEntry(
                name: name,
                isDirectory: attrs.pointee.type == UInt8(SSH_FILEXFER_TYPE_DIRECTORY),
                size: attrs.pointee.size,
                modificationTime: attrs.pointee.mtime64 > 0
                    ? attrs.pointee.mtime64
                    : UInt64(attrs.pointee.mtime)
            ))
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

    /// Size of a remote file, or nil when it isn't there. Resume probing asks
    /// about files that legitimately don't exist yet, and a thrown error would
    /// cost the caller its whole connection (see `HostSession`).
    func statIfPresent(_ remotePath: String) -> UInt64? {
        guard let sf = try? sftpSession() else { return nil }
        guard let attrs = sftp_stat(sf, remotePath) else { return nil }
        defer { sftp_attributes_free(attrs) }
        return attrs.pointee.size
    }

    func directoryExists(_ remotePath: String) throws -> Bool {
        let sf = try sftpSession()
        guard let attrs = sftp_stat(sf, remotePath) else { return false }
        defer { sftp_attributes_free(attrs) }
        return attrs.pointee.type == UInt8(SSH_FILEXFER_TYPE_DIRECTORY)
    }

    func removeFile(_ remotePath: String) throws {
        let sf = try sftpSession()
        guard sftp_unlink(sf, remotePath) == SSH_OK else { throw sftpError("unlink \(remotePath)") }
    }

    /// Removes an empty directory; a non-empty one fails with the server's error.
    func removeDirectory(_ remotePath: String) throws {
        let sf = try sftpSession()
        guard sftp_rmdir(sf, remotePath) == SSH_OK else { throw sftpError("rmdir \(remotePath)") }
    }

    func createDirectory(_ remotePath: String) throws {
        let sf = try sftpSession()
        guard sftp_mkdir(sf, remotePath, 0o755) == SSH_OK else {
            throw sftpError("mkdir \(remotePath)")
        }
    }

    func rename(_ fromPath: String, to toPath: String) throws {
        let sf = try sftpSession()
        guard sftp_rename(sf, fromPath, toPath) == SSH_OK else {
            throw sftpError("rename \(fromPath) → \(toPath)")
        }
    }

    // MARK: - Transfer tuning

    /// SFTP's request/response pattern caps a synchronous transfer at one
    /// chunk per round-trip, so throughput collapses with latency however much
    /// bandwidth is free — that, not the delta algorithm, is most of what makes
    /// rsync feel fast on a bad link. Keeping many requests in flight decouples
    /// the two. OpenSSH's own client holds 64 requests open; the window is
    /// sized in bytes here so a server advertising a large chunk can't balloon
    /// memory.
    private static let targetInFlightBytes = 8 << 20
    private static let maxPipelineDepth = 64
    private static let minPipelineDepth = 4

    private static func pipelineDepth(forChunk chunk: Int) -> Int {
        let byBytes = targetInFlightBytes / max(chunk, 1)
        return min(maxPipelineDepth, max(minPipelineDepth, byBytes))
    }

    /// A dropped Wi-Fi link or an expired NAT entry leaves the socket
    /// half-open: with no probes the transfer parks until libssh's own timeout
    /// fires, or indefinitely. Probing turns a dead link into a prompt error
    /// the resume path can act on — the sftp counterpart to the rsync command
    /// line's `ServerAliveInterval`.
    private func configureSocketKeepalive(_ s: ssh_session) {
        let fd = ssh_get_fd(s)
        guard fd >= 0 else { return }
        let size = socklen_t(MemoryLayout<CInt>.size)
        var enable: CInt = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &enable, size)
        var idle: CInt = 15
        _ = setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &idle, size)
        var interval: CInt = 5
        _ = setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &interval, size)
        var probes: CInt = 3
        _ = setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &probes, size)
    }

    // MARK: - Transfers

    /// Uploads over a pipelined write window. `resumeOffset` continues what a
    /// previous attempt left on the server; 0 truncates, so a shorter file
    /// never inherits a longer one's tail.
    func upload(
        localPath: String,
        remotePath: String,
        resumeFrom resumeOffset: UInt64 = 0,
        progress: (UInt64, UInt64) -> Bool
    ) throws {
        let sf = try sftpSession()
        let chunk = maxWriteChunk
        let depth = Self.pipelineDepth(forChunk: chunk)
        guard let local = FileHandle(forReadingAtPath: localPath) else {
            throw SSHEngineError.io("cannot open local file \(localPath)")
        }
        defer { try? local.close() }
        let total = localFileSize(localPath) ?? 0
        let startOffset = resumeOffset <= total ? resumeOffset : 0

        let flags = startOffset > 0 ? (O_WRONLY | O_CREAT) : (O_WRONLY | O_CREAT | O_TRUNC)
        guard let remote = sftp_open(sf, remotePath, flags, 0o644) else {
            throw sftpError("open \(remotePath) for writing")
        }
        var remoteClosed = false
        defer { if !remoteClosed { sftp_close(remote) } }

        if startOffset > 0 {
            guard sftp_seek64(remote, startOffset) == SSH_OK else {
                throw sftpError("seek \(remotePath) to byte \(startOffset)")
            }
            try local.seek(toOffset: startOffset)
        }

        var window: [(aio: sftp_aio?, length: Int)] = []
        window.reserveCapacity(depth)
        var confirmed = startOffset
        var queued = startOffset
        var reachedEOF = false

        // A begin_write leaves a reply queued inside libssh. Cancelling keeps
        // the session alive for the next call, so the window has to be waited
        // out rather than dropped; a hard failure discards the whole
        // connection (see HostSession), where freeing is enough.
        func drainWindow() {
            for entry in window {
                var aio = entry.aio
                guard aio != nil else { continue }
                _ = sftp_aio_wait_write(&aio)
                if aio != nil { sftp_aio_free(aio) }
            }
            window.removeAll()
        }
        defer { for entry in window where entry.aio != nil { sftp_aio_free(entry.aio) } }

        while true {
            guard progress(confirmed, total) else {
                drainWindow()
                throw SSHEngineError.cancelled
            }

            while !reachedEOF, window.count < depth {
                // Filling a deep window can push megabytes at the socket, so
                // cancellation is polled per chunk here too rather than only
                // once per completed request.
                guard progress(confirmed, total) else {
                    drainWindow()
                    throw SSHEngineError.cancelled
                }
                let data = try autoreleasepool { try local.read(upToCount: chunk) }
                guard let data, !data.isEmpty else {
                    reachedEOF = true
                    break
                }
                var aio: sftp_aio?
                let requested = data.withUnsafeBytes { raw in
                    sftp_aio_begin_write(remote, raw.baseAddress, raw.count, &aio)
                }
                guard requested > 0, aio != nil else {
                    throw sftpError("write to \(remotePath) at byte \(queued)")
                }
                window.append((aio: aio, length: requested))
                queued += UInt64(requested)
                // libssh caps a request at the server's max_write_length; any
                // remainder has to be re-read on the next pass.
                if requested < data.count {
                    try local.seek(toOffset: queued)
                }
            }

            guard !window.isEmpty else { break }

            let head = window.removeFirst()
            var aio = head.aio
            let written = sftp_aio_wait_write(&aio)
            if aio != nil { sftp_aio_free(aio) }
            guard written >= 0 else {
                throw sftpError("write to \(remotePath) at byte \(confirmed)")
            }
            confirmed += UInt64(written)
            guard written == head.length else {
                throw sftpError("short write to \(remotePath) at byte \(confirmed)")
            }
        }

        _ = progress(confirmed, total)
        remoteClosed = true
        guard sftp_close(remote) == SSH_OK else { throw sftpError("close \(remotePath)") }
    }

    /// Downloads over a pipelined read window, resuming from whatever the
    /// local staging file already holds.
    func download(
        remotePath: String,
        localPath: String,
        progress: (UInt64, UInt64) -> Bool
    ) throws {
        let sf = try sftpSession()
        let chunk = maxReadChunk
        let depth = Self.pipelineDepth(forChunk: chunk)
        let total = try stat(remotePath)
        let existingSize = localFileSize(localPath) ?? 0
        let resumeOffset = existingSize <= total ? existingSize : 0

        guard let remote = sftp_open(sf, remotePath, O_RDONLY, 0) else {
            throw sftpError("open \(remotePath) for reading")
        }
        var remoteClosed = false
        defer { if !remoteClosed { sftp_close(remote) } }

        if resumeOffset > 0 {
            guard sftp_seek64(remote, resumeOffset) == SSH_OK else {
                throw sftpError("seek \(remotePath) to byte \(resumeOffset)")
            }
        }

        if !FileManager.default.fileExists(atPath: localPath) {
            _ = FileManager.default.createFile(atPath: localPath, contents: nil)
        }
        guard let local = FileHandle(forWritingAtPath: localPath) else {
            throw SSHEngineError.io("cannot open local file \(localPath)")
        }
        defer { try? local.close() }
        if resumeOffset == 0 {
            try local.truncate(atOffset: 0)
        }
        try local.seek(toOffset: resumeOffset)

        var window: [(aio: sftp_aio?, length: Int)] = []
        window.reserveCapacity(depth)
        var buffer = [UInt8](repeating: 0, count: chunk)
        var received = resumeOffset
        var requested = resumeOffset

        func drainWindow() {
            guard !window.isEmpty else { return }
            var scratch = [UInt8](repeating: 0, count: chunk)
            for entry in window {
                var aio = entry.aio
                guard aio != nil else { continue }
                _ = scratch.withUnsafeMutableBytes {
                    sftp_aio_wait_read(&aio, $0.baseAddress!, chunk)
                }
                if aio != nil { sftp_aio_free(aio) }
            }
            window.removeAll()
        }
        defer { for entry in window where entry.aio != nil { sftp_aio_free(entry.aio) } }

        while true {
            guard progress(received, total) else {
                drainWindow()
                throw SSHEngineError.cancelled
            }

            while window.count < depth, requested < total {
                guard progress(received, total) else {
                    drainWindow()
                    throw SSHEngineError.cancelled
                }
                var aio: sftp_aio?
                let length = sftp_aio_begin_read(remote, chunk, &aio)
                guard length > 0, aio != nil else {
                    throw sftpError("read from \(remotePath) at byte \(requested)")
                }
                window.append((aio: aio, length: length))
                requested += UInt64(length)
            }

            guard !window.isEmpty else { break }

            let head = window.removeFirst()
            var aio = head.aio
            let n = buffer.withUnsafeMutableBytes {
                sftp_aio_wait_read(&aio, $0.baseAddress!, chunk)
            }
            if aio != nil { sftp_aio_free(aio) }
            if n == 0 {
                drainWindow()
                break
            }
            guard n > 0 else {
                throw sftpError("read from \(remotePath) at byte \(received)")
            }
            try buffer.withUnsafeBytes { raw in
                try autoreleasepool {
                    try local.write(contentsOf: Data(bytes: raw.baseAddress!, count: n))
                }
            }
            received += UInt64(n)

            // A short read leaves every queued request reading from an offset
            // that assumed a full chunk, which would punch a hole in the file.
            // Drop the window and re-seek to what actually landed.
            if n < head.length {
                drainWindow()
                guard sftp_seek64(remote, received) == SSH_OK else {
                    throw sftpError("seek \(remotePath) to byte \(received)")
                }
                requested = received
            }
        }

        _ = progress(received, total)
        remoteClosed = true
        guard sftp_close(remote) == SSH_OK else { throw sftpError("close \(remotePath)") }
    }

    // MARK: - Exec

    /// Runs one remote command over an exec channel (no PTY — sudo password,
    /// if any, is written to stdin per docs/research/rsync-detect-and-install.md).
    func exec(_ command: String, stdin stdinData: String? = nil) throws -> ExecResult {
        guard let s = session else { throw SSHEngineError.session("not connected") }
        guard let channel = ssh_channel_new(s) else {
            throw SSHEngineError.exec("channel_new failed: \(lastError(s))")
        }
        defer { ssh_channel_free(channel) }
        guard ssh_channel_open_session(channel) == SSH_OK else {
            throw SSHEngineError.exec("channel_open failed: \(lastError(s))")
        }
        defer { ssh_channel_close(channel) }
        let rc = command.withCString { ssh_channel_request_exec(channel, $0) }
        guard rc == SSH_OK else {
            throw SSHEngineError.exec("request_exec failed: \(lastError(s))")
        }
        if let stdinData {
            let bytes = Array(stdinData.utf8)
            let written = bytes.withUnsafeBytes {
                ssh_channel_write(channel, $0.baseAddress, UInt32($0.count))
            }
            guard written >= 0 else {
                throw SSHEngineError.exec("stdin write failed: \(lastError(s))")
            }
            ssh_channel_send_eof(channel)
        }

        var stdout = Data()
        var stderr = Data()
        var buffer = [UInt8](repeating: 0, count: 16 << 10)
        for isStderr: Int32 in [0, 1] {
            while true {
                let n = buffer.withUnsafeMutableBytes {
                    ssh_channel_read(channel, $0.baseAddress, UInt32($0.count), isStderr)
                }
                if n <= 0 { break }
                if isStderr == 1 {
                    stderr.append(contentsOf: buffer[0..<Int(n)])
                } else {
                    stdout.append(contentsOf: buffer[0..<Int(n)])
                }
            }
        }
        var status = UInt32.max
        _ = ssh_channel_get_exit_state(channel, &status, nil, nil)
        let exitStatus = Int32(bitPattern: status)
        return ExecResult(
            exitStatus: exitStatus,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self))
    }

    // MARK: - Errors

    private func lastError(_ s: ssh_session) -> String {
        String(cString: ssh_get_error(UnsafeMutableRawPointer(s)))
    }

    private func sftpError(_ what: String) -> SSHEngineError {
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

import Foundation

/// Retry policy shared by both transfer directions. A transfer that keeps
/// making progress earns its budget back, so a large file over a flaky link
/// finishes instead of spending the whole allowance on one bad stretch; the
/// deadline is what stops a genuinely dead link from looping forever.
enum TransferResumer {
    /// - Parameters:
    ///   - probeBeforeFirstAttempt: whether to ask `bytesTransferred` before
    ///     the first try. A download probes a local staging file for free and
    ///     wants whatever an earlier run left behind; an upload probe costs a
    ///     remote stat round-trip, so it only pays once something has failed.
    ///   - bytesTransferred: bytes already durable at the far end.
    ///   - attempt: runs one try, resuming from the offset it is handed.
    static func run(
        maxAttempts: Int = 6,
        baseRetryDelayNanoseconds: UInt64 = 500_000_000,
        maxRetryDelayNanoseconds: UInt64 = 15_000_000_000,
        totalRetryBudget: TimeInterval = 600,
        probeBeforeFirstAttempt: Bool = true,
        bytesTransferred: () async -> UInt64,
        attempt: (UInt64) async throws -> Void
    ) async throws {
        precondition(maxAttempts > 0)

        let startedAt = ProcessInfo.processInfo.systemUptime
        var remainingAttempts = maxAttempts
        var backoffStep = 0
        var resumeOffset: UInt64 = probeBeforeFirstAttempt ? await bytesTransferred() : 0

        while true {
            let before = resumeOffset
            do {
                try await attempt(before)
                return
            } catch SSHEngineError.cancelled {
                throw SSHEngineError.cancelled
            } catch {
                let after = await bytesTransferred()
                resumeOffset = after
                let madeProgress = after > before
                if madeProgress {
                    // The link is alive and the far end is growing: an
                    // interruption here costs a reconnect, not the budget.
                    remainingAttempts = maxAttempts
                    backoffStep = 0
                }
                remainingAttempts -= 1

                let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
                guard remainingAttempts > 0,
                      elapsed < totalRetryBudget,
                      shouldRetry(error, madeProgress: madeProgress) else {
                    throw error
                }
                guard !Task.isCancelled else { throw SSHEngineError.cancelled }

                let delay = retryDelay(
                    step: backoffStep,
                    base: baseRetryDelayNanoseconds,
                    cap: maxRetryDelayNanoseconds
                )
                backoffStep += 1
                if delay > 0 {
                    do {
                        try await Task.sleep(nanoseconds: delay)
                    } catch {
                        throw SSHEngineError.cancelled
                    }
                }
            }
        }
    }

    /// Exponential backoff with jitter. A fixed short delay burns every
    /// attempt inside a second — shorter than a Wi-Fi roam, a VPN
    /// re-handshake or a NAT rebuild, which turned recoverable blips into
    /// permanent failures. Jitter keeps files that dropped together from
    /// retrying in lockstep and colliding again.
    static func retryDelay(step: Int, base: UInt64, cap: UInt64) -> UInt64 {
        guard base > 0, cap > 0 else { return 0 }
        let shift = min(max(step, 0), 16)
        let scaled = base.multipliedReportingOverflow(by: 1 << UInt64(shift))
        let ceiling = scaled.overflow ? cap : min(scaled.partialValue, cap)
        return UInt64(Double(ceiling) * Double.random(in: 0.5...1.0))
    }

    private static func shouldRetry(_ error: Error, madeProgress: Bool) -> Bool {
        guard let engineError = error as? SSHEngineError else { return false }
        switch engineError {
        case .session:
            return true
        case .sftp(let message):
            return madeProgress
                || message.hasPrefix("read from ")
                || message.hasPrefix("write to ")
                || message.hasPrefix("short write to ")
                || message.hasPrefix("close ")
        case .auth, .hostKey, .io, .exec, .cancelled:
            return false
        }
    }
}

/// Async facade over one `SSHConnection`. libssh sessions are not thread-safe,
/// so every call is funnelled onto a per-host serial queue; the connection is
/// (re)established lazily and dropped on any session-level failure so the next
/// call reconnects.
final class HostSession: @unchecked Sendable {
    let record: HostRecord

    private let queue: DispatchQueue
    private var connection: SSHConnection?

    init(record: HostRecord) {
        self.record = record
        self.queue = DispatchQueue(label: "com.leafiy.joey.host.\(record.id.uuidString)")
    }

    /// Runs `body` with a live connection on the session queue. Cancellation is
    /// cooperative: long-running bodies poll `isCancelled` via their progress
    /// closures.
    private func withConnection<T>(_ body: @escaping (SSHConnection) throws -> T) async throws -> T {
        let record = record
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    if connection?.isConnected != true {
                        connection?.disconnect()
                        let fresh = SSHConnection(
                            host: record.host, port: UInt32(record.port), user: record.username)
                        try fresh.connect(auth: record.engineAuth)
                        connection = fresh
                    }
                    let result = try body(connection!)
                    continuation.resume(returning: result)
                } catch {
                    if case SSHEngineError.cancelled = error {
                        // Session stays usable after a clean cancel.
                    } else {
                        connection?.disconnect()
                        connection = nil
                    }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func disconnect() {
        queue.async { [self] in
            connection?.disconnect()
            connection = nil
        }
    }

    // MARK: - Operations

    func listDirectory(_ path: String) async throws -> [RemoteEntry] {
        try await withConnection { try $0.listDirectory(path) }
    }

    func homeDirectory() async throws -> String {
        try await withConnection { conn in
            let result = try conn.exec("pwd")
            let home = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return home.hasPrefix("/") ? home : "/"
        }
    }

    func createDirectory(_ path: String) async throws {
        try await withConnection { try $0.createDirectory(path) }
    }

    func rename(_ from: String, to: String) async throws {
        try await withConnection { try $0.rename(from, to: to) }
    }

    func remove(_ entry: RemoteEntry, at path: String) async throws {
        try await withConnection {
            if entry.isDirectory {
                try $0.removeDirectory(path)
            } else {
                try $0.removeFile(path)
            }
        }
    }

    func directoryExists(_ path: String) async throws -> Bool {
        try await withConnection { try $0.directoryExists(path) }
    }

    /// Bytes already on the server, or 0 when nothing is staged. A missing
    /// file is a normal answer here, so it must not surface as a thrown error:
    /// `withConnection` tears down the connection on anything it catches.
    func stagedByteCount(_ path: String) async -> UInt64 {
        let probed = try? await withConnection { $0.statIfPresent(path) }
        return probed.flatMap { $0 } ?? 0
    }

    /// Publishes a finished staging file under its real name. SFTP rename
    /// doesn't overwrite on most servers (Windows OpenSSH included), so the
    /// previous file goes first; the staged copy is already complete, which
    /// keeps the window where neither name exists to one round-trip.
    func publishStagedUpload(from stagingPath: String, to finalPath: String) async throws {
        try await withConnection { conn in
            if conn.statIfPresent(finalPath) != nil {
                try? conn.removeFile(finalPath)
            }
            try conn.rename(stagingPath, to: finalPath)
        }
    }

    func discardStagedUpload(_ stagingPath: String) async {
        _ = try? await withConnection { try? $0.removeFile(stagingPath) }
    }

    /// `progress` is invoked on the session queue; return `false` to cancel.
    /// An interrupted upload resumes from the bytes already on the server
    /// rather than restarting the file — the sftp path has no rsync
    /// `--partial` to fall back on.
    func upload(
        localPath: String, remotePath: String,
        progress: @escaping (UInt64, UInt64) -> Bool
    ) async throws {
        try await TransferResumer.run(
            probeBeforeFirstAttempt: false,
            bytesTransferred: { await self.stagedByteCount(remotePath) },
            attempt: { resumeOffset in
                try await self.withConnection {
                    try $0.upload(
                        localPath: localPath,
                        remotePath: remotePath,
                        resumeFrom: resumeOffset,
                        progress: progress
                    )
                }
            }
        )
    }

    func download(
        remotePath: String, localPath: String,
        progress: @escaping (UInt64, UInt64) -> Bool
    ) async throws {
        try await TransferResumer.run(
            bytesTransferred: { localFileSize(localPath) ?? 0 },
            attempt: { _ in
                // The engine reads the staged file's length itself, so the
                // probed offset is only used to judge whether progress happened.
                try await self.withConnection {
                    try $0.download(
                        remotePath: remotePath,
                        localPath: localPath,
                        progress: progress
                    )
                }
            }
        )
    }

    func exec(_ command: String, stdin: String? = nil) async throws -> ExecResult {
        try await withConnection { try $0.exec(command, stdin: stdin) }
    }
}

import Foundation

/// Async facade over one `SSHConnection`. libssh sessions are not thread-safe,
/// so every call is funnelled onto a per-host serial queue; the connection is
/// (re)established lazily and dropped on any session-level failure so the next
/// call reconnects.
final class HostSession {
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

    /// `progress` is invoked on the session queue; return `false` to cancel.
    func upload(
        localPath: String, remotePath: String,
        progress: @escaping (UInt64, UInt64) -> Bool
    ) async throws {
        try await withConnection {
            try $0.upload(localPath: localPath, remotePath: remotePath, progress: progress)
        }
    }

    func download(
        remotePath: String, localPath: String,
        progress: @escaping (UInt64, UInt64) -> Bool
    ) async throws {
        try await withConnection {
            try $0.download(remotePath: remotePath, localPath: localPath, progress: progress)
        }
    }

    func exec(_ command: String, stdin: String? = nil) async throws -> ExecResult {
        try await withConnection { try $0.exec(command, stdin: stdin) }
    }
}

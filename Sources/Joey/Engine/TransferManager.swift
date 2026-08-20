import Foundation

/// One upload or download (CONTEXT.md: Transfer). rsync when possible,
/// otherwise sftp; the user never sees which protocol ran.
struct TransferError: Identifiable {
    let id = UUID()
    /// Error Banner summary: which file, what went wrong.
    let fileName: String
    let message: String
}

/// Serializes all Transfers and feeds the two failure surfaces the family
/// allows: the menubar Status-Dot (busy / error states) and the panel's Error
/// Banner. No dialogs, no system notifications.
@MainActor
final class TransferManager: ObservableObject {
    enum DotState {
        case idle
        case busy
        case error
        case success
    }

    @Published private(set) var dotState: DotState = .idle
    @Published private(set) var activeCount = 0
    @Published var lastError: TransferError?

    /// Remembered per-host remote rsync state, refreshed per app run.
    private var remoteRsync: [UUID: RsyncSupport.RemoteState] = [:]
    private let localRsync = RsyncSupport.findLocalRsync()

    var isLocalRsyncAvailable: Bool { localRsync != nil }

    // MARK: - Status-Dot bookkeeping

    private func began() {
        activeCount += 1
        dotState = .busy
    }

    private func finished(error: TransferError?) {
        activeCount -= 1
        if let error {
            lastError = error
            dotState = .error
            return
        }
        if activeCount == 0 && dotState != .error {
            dotState = .success
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.activeCount == 0, self.dotState == .success else { return }
                self.dotState = .idle
            }
        }
    }

    func clearError() {
        lastError = nil
        if dotState == .error { dotState = activeCount > 0 ? .busy : .idle }
    }

    // MARK: - Uploads

    /// Uploads local files into `directory` on the session's host. Directories
    /// dropped from Finder are walked recursively over sftp; rsync handles
    /// them natively.
    func upload(urls: [URL], to directory: String, session: HostSession) async {
        for url in urls {
            began()
            let name = url.lastPathComponent
            do {
                if await shouldUseRsync(session: session) {
                    try await rsyncUpload(url: url, to: directory, session: session)
                } else {
                    try await sftpUpload(url: url, to: directory, session: session)
                }
                finished(error: nil)
            } catch SSHEngineError.cancelled {
                finished(error: nil)
            } catch {
                finished(error: TransferError(fileName: name, message: "\(error)"))
            }
        }
    }

    private func sftpUpload(url: URL, to directory: String, session: HostSession) async throws {
        let remoteBase = joinRemote(directory, url.lastPathComponent)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            try? await session.createDirectory(remoteBase)
            let children = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil)) ?? []
            for child in children {
                try await sftpUpload(url: child, to: remoteBase, session: session)
            }
        } else {
            try await session.upload(localPath: url.path, remotePath: remoteBase) { _, _ in true }
        }
    }

    private func rsyncUpload(url: URL, to directory: String, session: HostSession) async throws {
        guard let local = localRsync else {
            try await sftpUpload(url: url, to: directory, session: session)
            return
        }
        let record = session.record
        let keyPath = (record.privateKeyPath as NSString).expandingTildeInPath
        let args = RsyncSupport.uploadArguments(
            localPath: url.path, record: record, keyPath: keyPath,
            remoteDirectory: directory, modern: local.modern)

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: local.path)
            process.arguments = args
            // Progress output is discarded (Status-Dot is the only feedback);
            // null-routing also keeps an undrained pipe from stalling rsync.
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { p in
                continuation.resume(returning: p.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        // Any rsync failure falls back to sftp (research doc: keep the sftp
        // fallback on any non-zero exit).
        if status != 0 {
            try await sftpUpload(url: url, to: directory, session: session)
        }
    }

    // MARK: - Downloads (Drag-out)

    /// Downloads one remote file to a local destination; used by the file
    /// promise once the drop location is known. `progress` is the receiver's
    /// `Progress` (Finder shows it); cancelling it aborts the transfer.
    func download(
        remotePath: String, fileName: String, to localURL: URL, session: HostSession,
        progress: Progress? = nil
    ) async throws {
        began()
        do {
            try await session.download(remotePath: remotePath, localPath: localURL.path) { done, total in
                guard let progress else { return true }
                if total > 0 { progress.totalUnitCount = Int64(total) }
                progress.completedUnitCount = Int64(done)
                return !progress.isCancelled
            }
            finished(error: nil)
        } catch SSHEngineError.cancelled {
            finished(error: nil)
            throw SSHEngineError.cancelled
        } catch {
            finished(error: TransferError(fileName: fileName, message: "\(error)"))
            throw error
        }
    }

    // MARK: - rsync availability

    func shouldUseRsync(session: HostSession) async -> Bool {
        guard session.record.supportsRsync, localRsync != nil else { return false }
        if case .present = await remoteRsyncState(session: session) { return true }
        return false
    }

    func remoteRsyncState(session: HostSession) async -> RsyncSupport.RemoteState {
        let hostID = session.record.id
        if let cached = remoteRsync[hostID] { return cached }
        let state: RsyncSupport.RemoteState
        if let result = try? await session.exec(RsyncSupport.detectCommand) {
            state = RsyncSupport.parseDetection(result)
        } else {
            state = .unknown(detail: "probe failed")
        }
        remoteRsync[hostID] = state
        return state
    }

    func invalidateRsyncState(hostID: UUID) {
        remoteRsync.removeValue(forKey: hostID)
    }
}

func joinRemote(_ directory: String, _ name: String) -> String {
    directory.hasSuffix("/") ? directory + name : directory + "/" + name
}

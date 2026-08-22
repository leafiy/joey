import Foundation

/// One upload or download (CONTEXT.md: Transfer). rsync when possible,
/// otherwise sftp; the user never sees which protocol ran.
struct TransferError: Identifiable {
    let id = UUID()
    /// Error Banner summary: which file, what went wrong.
    let fileName: String
    let message: String
}

struct DownloadCheckpoint: Codable, Equatable {
    let size: UInt64
    let modificationTime: UInt64
}

protocol RemoteDownloadSession: AnyObject {
    func listDirectory(_ path: String) async throws -> [RemoteEntry]
    func download(
        remotePath: String,
        localPath: String,
        progress: @escaping (UInt64, UInt64) -> Bool
    ) async throws
}

extension HostSession: RemoteDownloadSession {}

/// Thread-safe aggregate throughput sampling for concurrent transfer streams.
/// Streams report cumulative byte counts; resets between rsync files are
/// treated as a new file rather than negative progress.
final class TransferSpeedSampler: @unchecked Sendable {
    private struct Stream {
        var lastBytes: UInt64?
    }

    private let lock = NSLock()
    private let sampleInterval: TimeInterval
    private var streams: [UUID: Stream] = [:]
    private var sampleStartedAt: TimeInterval?
    private var bytesSinceSample: UInt64 = 0

    init(sampleInterval: TimeInterval = 0.5) {
        self.sampleInterval = sampleInterval
    }

    func reset(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        streams.removeAll(keepingCapacity: true)
        sampleStartedAt = now
        bytesSinceSample = 0
        lock.unlock()
    }

    func begin(_ id: UUID, initialBytes: UInt64? = nil) {
        lock.lock()
        streams[id] = Stream(lastBytes: initialBytes)
        lock.unlock()
    }

    func finish(_ id: UUID) {
        lock.lock()
        streams[id] = nil
        lock.unlock()
    }

    func record(
        _ bytes: UInt64,
        for id: UUID,
        at now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Double? {
        lock.lock()
        defer { lock.unlock() }

        guard var stream = streams[id] else { return nil }
        if let previous = stream.lastBytes {
            let delta = bytes >= previous ? bytes - previous : bytes
            bytesSinceSample &+= delta
        }
        stream.lastBytes = bytes
        streams[id] = stream

        guard let startedAt = sampleStartedAt else {
            sampleStartedAt = now
            return nil
        }
        let elapsed = now - startedAt
        guard elapsed >= sampleInterval, bytesSinceSample > 0 else { return nil }

        let rate = Double(bytesSinceSample) / elapsed
        sampleStartedAt = now
        bytesSinceSample = 0
        return rate
    }
}

private final class RsyncProgressBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""

    func append(_ data: Data, flush: Bool = false) -> [UInt64] {
        lock.lock()
        defer { lock.unlock() }

        pending += String(decoding: data, as: UTF8.self)
        let lines = pending.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "\r" || $0 == "\n" }
        )
        let completed: Array<Substring>
        if flush {
            completed = Array(lines)
            pending = ""
        } else {
            completed = Array(lines.dropLast())
            pending = lines.last.map(String.init) ?? ""
        }
        return completed.compactMap { RsyncSupport.parseProgressBytes(String($0)) }
    }
}

/// Generation tokens let one cancel action stop every currently active
/// transfer without poisoning transfers started afterward.
final class TransferCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func token() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func cancelAll() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    func isCurrent(_ token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == token
    }
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
    @Published private(set) var currentBytesPerSecond: Double?
    @Published private(set) var isCancelling = false

    private let speedSampler = TransferSpeedSampler()
    private let cancellationState = TransferCancellationState()
    private var speedExpiryTask: Task<Void, Never>?
    private var activeRsyncProcesses: [UUID: Process] = [:]

    /// Remembered per-host remote rsync state, refreshed per app run.
    private var remoteRsync: [UUID: RsyncSupport.RemoteState] = [:]
    private let localRsync = RsyncSupport.findLocalRsync()

    var isLocalRsyncAvailable: Bool { localRsync != nil }

    // MARK: - Status-Dot bookkeeping

    @discardableResult
    private func began() -> UInt64 {
        if activeCount == 0 {
            speedSampler.reset()
            currentBytesPerSecond = nil
            isCancelling = false
        }
        let token = cancellationState.token()
        activeCount += 1
        dotState = .busy
        return token
    }

    private func finished(error: TransferError?) {
        activeCount -= 1
        if activeCount == 0 {
            speedSampler.reset()
            speedExpiryTask?.cancel()
            speedExpiryTask = nil
            currentBytesPerSecond = nil
            isCancelling = false
        }
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

    var formattedSpeed: String? {
        guard let currentBytesPerSecond else { return nil }
        return Self.speedFormatter.string(
            fromByteCount: Int64(currentBytesPerSecond.rounded())
        ) + "/s"
    }

    private static let speedFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesActualByteCount = false
        return formatter
    }()

    private func speedReporter(for id: UUID) -> (UInt64) -> Void {
        let sampler = speedSampler
        return { [weak self] bytes in
            guard let rate = sampler.record(bytes, for: id) else { return }
            Task { @MainActor [weak self] in
                self?.publishSpeed(rate)
            }
        }
    }

    private func publishSpeed(_ bytesPerSecond: Double) {
        guard activeCount > 0 else { return }
        currentBytesPerSecond = bytesPerSecond
        speedExpiryTask?.cancel()
        speedExpiryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
            guard let self, self.activeCount > 0 else { return }
            self.currentBytesPerSecond = nil
        }
    }

    func cancelActiveTransfers() {
        guard activeCount > 0, !isCancelling else { return }
        isCancelling = true
        cancellationState.cancelAll()
        for process in activeRsyncProcesses.values where process.isRunning {
            process.terminate()
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
            let cancellationToken = began()
            let name = url.lastPathComponent
            do {
                let useRsync = await shouldUseRsync(session: session)
                guard cancellationState.isCurrent(cancellationToken) else {
                    throw SSHEngineError.cancelled
                }
                if useRsync {
                    try await rsyncUpload(
                        url: url,
                        to: directory,
                        session: session,
                        cancellationToken: cancellationToken
                    )
                } else {
                    try await sftpUpload(
                        url: url,
                        to: directory,
                        session: session,
                        cancellationToken: cancellationToken
                    )
                }
                finished(error: nil)
            } catch SSHEngineError.cancelled {
                finished(error: nil)
                break
            } catch {
                finished(error: TransferError(
                    fileName: name,
                    message: UserFacingError.message(for: error, during: .upload)))
            }
        }
    }

    private func sftpUpload(
        url: URL,
        to directory: String,
        session: HostSession,
        cancellationToken: UInt64
    ) async throws {
        guard cancellationState.isCurrent(cancellationToken) else {
            throw SSHEngineError.cancelled
        }
        let remoteBase = joinRemote(directory, url.lastPathComponent)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            try? await session.createDirectory(remoteBase)
            guard cancellationState.isCurrent(cancellationToken) else {
                throw SSHEngineError.cancelled
            }
            let children = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil)) ?? []
            for child in children {
                try await sftpUpload(
                    url: child,
                    to: remoteBase,
                    session: session,
                    cancellationToken: cancellationToken
                )
            }
        } else {
            let streamID = UUID()
            let cancellationState = cancellationState
            speedSampler.begin(streamID, initialBytes: 0)
            let reportSpeed = speedReporter(for: streamID)
            defer { speedSampler.finish(streamID) }
            try await session.upload(localPath: url.path, remotePath: remoteBase) { done, _ in
                reportSpeed(done)
                return cancellationState.isCurrent(cancellationToken)
            }
            guard cancellationState.isCurrent(cancellationToken) else {
                throw SSHEngineError.cancelled
            }
        }
    }

    private func rsyncUpload(
        url: URL,
        to directory: String,
        session: HostSession,
        cancellationToken: UInt64
    ) async throws {
        guard let local = localRsync else {
            try await sftpUpload(
                url: url,
                to: directory,
                session: session,
                cancellationToken: cancellationToken
            )
            return
        }
        guard cancellationState.isCurrent(cancellationToken) else {
            throw SSHEngineError.cancelled
        }

        let record = session.record
        let keyPath = (record.privateKeyPath as NSString).expandingTildeInPath
        let args = RsyncSupport.uploadArguments(
            localPath: url.path, record: record, keyPath: keyPath,
            remoteDirectory: directory, modern: local.modern)
        let streamID = UUID()
        speedSampler.begin(streamID, initialBytes: 0)
        let reportSpeed = speedReporter(for: streamID)
        defer { speedSampler.finish(streamID) }

        let process = Process()
        let progressPipe = Pipe()
        let progressBuffer = RsyncProgressBuffer()
        process.executableURL = URL(fileURLWithPath: local.path)
        process.arguments = args
        process.standardOutput = progressPipe
        process.standardError = FileHandle.nullDevice
        progressPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for bytes in progressBuffer.append(data) {
                reportSpeed(bytes)
            }
        }
        activeRsyncProcesses[streamID] = process
        defer { activeRsyncProcesses[streamID] = nil }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                progressPipe.fileHandleForReading.readabilityHandler = nil
                let remaining = progressPipe.fileHandleForReading.readDataToEndOfFile()
                for bytes in progressBuffer.append(remaining, flush: true) {
                    reportSpeed(bytes)
                }
                continuation.resume(returning: process.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                progressPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard cancellationState.isCurrent(cancellationToken) else {
            throw SSHEngineError.cancelled
        }
        // Any rsync failure falls back to sftp (research doc: keep the sftp
        // fallback on any non-zero exit).
        if status != 0 {
            try await sftpUpload(
                url: url,
                to: directory,
                session: session,
                cancellationToken: cancellationToken
            )
        }
    }

    // MARK: - Downloads

    /// Downloads one remote file or folder to a local destination. Data is
    /// written to a hidden sibling first, so an interrupted transfer can
    /// resume without exposing an incomplete destination to Finder.
    func download(
        entry: RemoteEntry,
        remotePath: String,
        to localURL: URL,
        session: any RemoteDownloadSession,
        progress: Progress? = nil
    ) async throws {
        let cancellationToken = began()
        do {
            try await stageDownload(
                entry: entry,
                remotePath: remotePath,
                finalURL: localURL,
                session: session,
                progress: entry.isDirectory ? nil : progress,
                replaceExisting: false,
                cancellationToken: cancellationToken
            )
            finished(error: nil)
        } catch SSHEngineError.cancelled {
            finished(error: nil)
            throw SSHEngineError.cancelled
        } catch {
            finished(error: TransferError(
                fileName: entry.name,
                message: UserFacingError.message(for: error, during: .download)
            ))
            throw error
        }
    }

    /// Downloads remote items into the configured local directory. Existing
    /// completed items are preserved by choosing a numbered destination.
    func download(
        entries: [RemoteEntry],
        from remoteDirectory: String,
        to localDirectory: URL,
        session: any RemoteDownloadSession
    ) async {
        guard !entries.isEmpty else { return }

        do {
            try FileManager.default.createDirectory(
                at: localDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            began()
            finished(error: TransferError(
                fileName: entries[0].name,
                message: UserFacingError.message(for: error, during: .download)
            ))
            return
        }

        for entry in entries {
            let destination = Self.availableDownloadURL(
                fileName: entry.name,
                in: localDirectory
            )
            do {
                try await download(
                    entry: entry,
                    remotePath: joinRemote(remoteDirectory, entry.name),
                    to: destination,
                    session: session
                )
            } catch SSHEngineError.cancelled {
                break
            } catch {
                // `download` records the user-facing error and balances the
                // activity count. Continue with the rest of the selection.
            }
        }
    }

    private func stageDownload(
        entry: RemoteEntry,
        remotePath: String,
        finalURL: URL,
        session: any RemoteDownloadSession,
        progress: Progress?,
        replaceExisting: Bool,
        cancellationToken: UInt64
    ) async throws {
        guard cancellationState.isCurrent(cancellationToken) else {
            throw SSHEngineError.cancelled
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: finalURL.path) {
            guard replaceExisting else {
                throw SSHEngineError.io("local item already exists at \(finalURL.path)")
            }
            try fileManager.removeItem(at: finalURL)
        }

        let partialURL = Self.partialDownloadURL(for: finalURL)
        if entry.isDirectory {
            var partialIsDirectory: ObjCBool = false
            if fileManager.fileExists(
                atPath: partialURL.path,
                isDirectory: &partialIsDirectory
            ), !partialIsDirectory.boolValue {
                try fileManager.removeItem(at: partialURL)
            }
            try fileManager.createDirectory(
                at: partialURL,
                withIntermediateDirectories: true
            )
            let children = try await session.listDirectory(remotePath)
            guard cancellationState.isCurrent(cancellationToken) else {
                throw SSHEngineError.cancelled
            }
            for child in children {
                try await stageDownload(
                    entry: child,
                    remotePath: joinRemote(remotePath, child.name),
                    finalURL: partialURL.appendingPathComponent(
                        child.name,
                        isDirectory: child.isDirectory
                    ),
                    session: session,
                    progress: nil,
                    replaceExisting: true,
                    cancellationToken: cancellationToken
                )
            }
        } else {
            try fileManager.createDirectory(
                at: partialURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Self.preparePartialDownload(
                for: entry,
                at: partialURL,
                fileManager: fileManager
            )
            let streamID = UUID()
            let cancellationState = cancellationState
            speedSampler.begin(streamID)
            let reportSpeed = speedReporter(for: streamID)
            defer { speedSampler.finish(streamID) }
            try await session.download(
                remotePath: remotePath,
                localPath: partialURL.path
            ) { done, total in
                reportSpeed(done)
                if let progress {
                    if total > 0 { progress.totalUnitCount = Int64(total) }
                    progress.completedUnitCount = Int64(done)
                }
                return cancellationState.isCurrent(cancellationToken)
                    && progress?.isCancelled != true
            }
        }

        guard cancellationState.isCurrent(cancellationToken) else {
            throw SSHEngineError.cancelled
        }
        try fileManager.moveItem(at: partialURL, to: finalURL)
        if !entry.isDirectory {
            try? fileManager.removeItem(at: Self.checkpointURL(for: partialURL))
        }
    }

    static func partialDownloadURL(for finalURL: URL) -> URL {
        finalURL.deletingLastPathComponent().appendingPathComponent(
            ".\(finalURL.lastPathComponent).joeydownload",
            isDirectory: finalURL.hasDirectoryPath
        )
    }

    static func checkpointURL(for partialURL: URL) -> URL {
        partialURL.appendingPathExtension("metadata")
    }

    static func preparePartialDownload(
        for entry: RemoteEntry,
        at partialURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let checkpointURL = checkpointURL(for: partialURL)
        let expected = DownloadCheckpoint(
            size: entry.size,
            modificationTime: entry.modificationTime
        )

        if fileManager.fileExists(atPath: partialURL.path) {
            let saved: DownloadCheckpoint?
            if let data = try? Data(contentsOf: checkpointURL) {
                saved = try? JSONDecoder().decode(DownloadCheckpoint.self, from: data)
            } else {
                saved = nil
            }
            if saved != expected {
                try fileManager.removeItem(at: partialURL)
            }
        }

        let data = try JSONEncoder().encode(expected)
        try data.write(to: checkpointURL, options: .atomic)
    }

    static func availableDownloadURL(
        fileName: String,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let original = directory.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: original.path) else { return original }

        let source = URL(fileURLWithPath: fileName)
        let pathExtension = source.pathExtension
        let stem = source.deletingPathExtension().lastPathComponent
        let extensionSuffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        var index = 2
        while true {
            let candidate = directory.appendingPathComponent(
                "\(stem) (\(index))\(extensionSuffix)"
            )
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
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
    let separator = directory.contains("\\") ? "\\" : "/"
    return directory.hasSuffix(separator) ? directory + name : directory + separator + name
}

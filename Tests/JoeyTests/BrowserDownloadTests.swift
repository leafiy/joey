import XCTest
import UniformTypeIdentifiers
@testable import Joey

@MainActor

final class BrowserDownloadTests: XCTestCase {
    func testEffectiveEntriesUsesTheClickedRowOrTheWholeSelection() {
        let folder = RemoteEntry(name: "Folder", isDirectory: true, size: 0)
        let first = RemoteEntry(name: "first.txt", isDirectory: false, size: 10)
        let second = RemoteEntry(name: "second.txt", isDirectory: false, size: 20)
        let entries = [folder, first, second]
        let selection: Set<RemoteEntry.ID> = [first.id, second.id]

        XCTAssertEqual(
            BrowserModel.effectiveEntries(
                for: first,
                selection: selection,
                in: entries
            ),
            [first, second]
        )
        XCTAssertEqual(
            BrowserModel.effectiveEntries(
                for: folder,
                selection: selection,
                in: entries
            ),
            [folder]
        )
    }

    func testAvailableDownloadURLPreservesExistingFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("joey-download-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = directory.appendingPathComponent("report.pdf")
        let second = directory.appendingPathComponent("report (2).pdf")
        XCTAssertTrue(FileManager.default.createFile(atPath: original.path, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: second.path, contents: Data()))

        XCTAssertEqual(
            TransferManager.availableDownloadURL(fileName: "report.pdf", in: directory),
            directory.appendingPathComponent("report (3).pdf")
        )
        XCTAssertEqual(
            TransferManager.availableDownloadURL(fileName: "notes.txt", in: directory),
            directory.appendingPathComponent("notes.txt")
        )
    }

    func testFolderDragUsesTheSystemFolderType() {
        let folder = RemoteEntry(name: "Photos", isDirectory: true, size: 0)
        let file = RemoteEntry(name: "photo.jpg", isDirectory: false, size: 20)

        XCTAssertEqual(JoeyModel.dragContentType(for: folder), .folder)
        XCTAssertEqual(JoeyModel.dragContentType(for: file), .jpeg)
    }

    func testPartialDownloadUsesHiddenSibling() {
        let destination = URL(fileURLWithPath: "/tmp/report.pdf")
        XCTAssertEqual(
            TransferManager.partialDownloadURL(for: destination),
            URL(fileURLWithPath: "/tmp/.report.pdf.joeydownload")
        )
    }

    func testDownloadResumerContinuesFromPartialData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("joey-resume-tests-\(UUID().uuidString)", isDirectory: true)
        let partial = directory.appendingPathComponent(".archive.zip.joeydownload")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        XCTAssertTrue(FileManager.default.createFile(
            atPath: partial.path,
            contents: Data([0, 1, 2])
        ))
        defer { try? FileManager.default.removeItem(at: directory) }

        var attempts = 0
        try await DownloadResumer.run(
            localPath: partial.path,
            maxAttempts: 3,
            retryDelayNanoseconds: 0
        ) {
            attempts += 1
            if attempts == 1 {
                let handle = try FileHandle(forWritingTo: partial)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([3, 4]))
                try handle.close()
                throw SSHEngineError.sftp("read from archive.zip at byte 5")
            }
            XCTAssertEqual(localFileSize(partial.path), 5)
        }

        XCTAssertEqual(attempts, 2)
    }

    func testChangedRemoteFileDiscardsStalePartialData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("joey-checkpoint-tests-\(UUID().uuidString)", isDirectory: true)
        let partial = directory.appendingPathComponent(".report.pdf.joeydownload")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = RemoteEntry(
            name: "report.pdf",
            isDirectory: false,
            size: 10,
            modificationTime: 100
        )
        try TransferManager.preparePartialDownload(for: original, at: partial)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: partial.path,
            contents: Data([0, 1, 2])
        ))

        try TransferManager.preparePartialDownload(for: original, at: partial)
        XCTAssertEqual(localFileSize(partial.path), 3)

        let changed = RemoteEntry(
            name: "report.pdf",
            isDirectory: false,
            size: 10,
            modificationTime: 101
        )
        try TransferManager.preparePartialDownload(for: changed, at: partial)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testDownloadResumerDoesNotRetryPermanentErrors() async {
        let partial = FileManager.default.temporaryDirectory
            .appendingPathComponent(".joey-permanent-error-\(UUID().uuidString)")
        var attempts = 0

        do {
            try await DownloadResumer.run(
                localPath: partial.path,
                maxAttempts: 3,
                retryDelayNanoseconds: 0
            ) {
                attempts += 1
                throw SSHEngineError.auth("rejected")
            }
            XCTFail("Expected authentication failure")
        } catch {
            XCTAssertEqual(attempts, 1)
        }
    }

    func testFolderDownloadBuildsNestedTreeBeforePublishingDestination() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("joey-folder-tests-\(UUID().uuidString)", isDirectory: true)
        let destination = directory.appendingPathComponent("Album", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let songData = Data("track".utf8)
        let session = FakeRemoteDownloadSession(
            directories: [
                "/Album": [
                    RemoteEntry(
                        name: "song.txt",
                        isDirectory: false,
                        size: UInt64(songData.count),
                        modificationTime: 10
                    ),
                    RemoteEntry(name: "Empty", isDirectory: true, size: 0),
                ],
                "/Album/Empty": [],
            ],
            files: ["/Album/song.txt": songData]
        )
        let manager = TransferManager()

        try await manager.download(
            entry: RemoteEntry(name: "Album", isDirectory: true, size: 0),
            remotePath: "/Album",
            to: destination,
            session: session
        )

        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("song.txt")),
            songData
        )
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("Empty").path,
            isDirectory: &isDirectory
        ))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: TransferManager.partialDownloadURL(for: destination).path
        ))
    }

    func testDownloadPublishesFormattedTransferSpeedWhileActive() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("joey-speed-tests-\(UUID().uuidString)", isDirectory: true)
        let destination = directory.appendingPathComponent("payload.bin")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = TransferManager()
        let entry = RemoteEntry(
            name: "payload.bin",
            isDirectory: false,
            size: 1_000_000,
            modificationTime: 1
        )
        let transfer = Task {
            try await manager.download(
                entry: entry,
                remotePath: "/payload.bin",
                to: destination,
                session: SlowRemoteDownloadSession()
            )
        }

        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(manager.activeCount, 1)
        XCTAssertGreaterThan(manager.currentBytesPerSecond ?? 0, 0)
        XCTAssertTrue(manager.formattedSpeed?.hasSuffix("/s") == true)

        try await transfer.value
        XCTAssertNil(manager.currentBytesPerSecond)
        XCTAssertNil(manager.formattedSpeed)
    }

    func testCancelActiveTransfersStopsDownloadAndAllowsTheNextOne() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("joey-cancel-tests-\(UUID().uuidString)", isDirectory: true)
        let destination = directory.appendingPathComponent("payload.bin")
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = TransferManager()
        let entry = RemoteEntry(
            name: "payload.bin",
            isDirectory: false,
            size: 1_000_000,
            modificationTime: 1
        )
        let transfer = Task { () -> Error? in
            do {
                try await manager.download(
                    entry: entry,
                    remotePath: "/payload.bin",
                    to: destination,
                    session: SlowRemoteDownloadSession()
                )
                return nil
            } catch {
                return error
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(manager.activeCount, 1)
        manager.cancelActiveTransfers()
        XCTAssertTrue(manager.isCancelling)

        let error = await transfer.value
        guard let engineError = error as? SSHEngineError,
              case .cancelled = engineError else {
            return XCTFail("the active download should end through the clean cancellation path")
        }
        XCTAssertEqual(manager.activeCount, 0)
        XCTAssertFalse(manager.isCancelling)
        XCTAssertNil(manager.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: TransferManager.partialDownloadURL(for: destination).path
        ))

        let retryData = Data("next transfer".utf8)
        let retryDestination = directory.appendingPathComponent("retry.txt")
        try await manager.download(
            entry: RemoteEntry(
                name: "retry.txt",
                isDirectory: false,
                size: UInt64(retryData.count),
                modificationTime: 2
            ),
            remotePath: "/retry.txt",
            to: retryDestination,
            session: FakeRemoteDownloadSession(
                directories: [:],
                files: ["/retry.txt": retryData]
            )
        )
        XCTAssertEqual(try Data(contentsOf: retryDestination), retryData)
    }
}

private final class FakeRemoteDownloadSession: RemoteDownloadSession {
    let directories: [String: [RemoteEntry]]
    let files: [String: Data]

    init(directories: [String: [RemoteEntry]], files: [String: Data]) {
        self.directories = directories
        self.files = files
    }

    func listDirectory(_ path: String) async throws -> [RemoteEntry] {
        guard let entries = directories[path] else {
            throw SSHEngineError.sftp("missing fake directory \(path)")
        }
        return entries
    }

    func download(
        remotePath: String,
        localPath: String,
        progress: @escaping (UInt64, UInt64) -> Bool
    ) async throws {
        guard let data = files[remotePath] else {
            throw SSHEngineError.sftp("missing fake file \(remotePath)")
        }
        if !FileManager.default.fileExists(atPath: localPath) {
            _ = FileManager.default.createFile(atPath: localPath, contents: nil)
        }
        let offset = min(localFileSize(localPath) ?? 0, UInt64(data.count))
        guard progress(offset, UInt64(data.count)) else {
            throw SSHEngineError.cancelled
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: localPath))
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: Data(data.dropFirst(Int(offset))))
        try handle.close()
        _ = progress(UInt64(data.count), UInt64(data.count))
    }
}

private final class SlowRemoteDownloadSession: RemoteDownloadSession {
    func listDirectory(_ path: String) async throws -> [RemoteEntry] {
        []
    }

    func download(
        remotePath: String,
        localPath: String,
        progress: @escaping (UInt64, UInt64) -> Bool
    ) async throws {
        let total: UInt64 = 1_000_000
        guard progress(0, total) else { throw SSHEngineError.cancelled }
        try await Task.sleep(nanoseconds: 600_000_000)
        try Data(repeating: 0, count: Int(total)).write(
            to: URL(fileURLWithPath: localPath)
        )
        guard progress(total, total) else { throw SSHEngineError.cancelled }
        try await Task.sleep(nanoseconds: 600_000_000)
    }
}

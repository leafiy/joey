import CLibssh
import CryptoKit
import Foundation

// Set from the SIGINT handler; every transfer's progress closure checks it so
// Ctrl-C exercises the same clean-cancel path as the automated cancel test.
var gInterrupted: sig_atomic_t = 0

func installSigintHandler() {
    signal(SIGINT) { _ in gInterrupted = 1 }
}

final class ProgressPrinter {
    private let label: String
    private let start = Date()
    private var lastLine = Date.distantPast

    init(_ label: String) { self.label = label }

    var elapsed: TimeInterval { Date().timeIntervalSince(start) }

    func update(done: UInt64, total: UInt64) {
        let now = Date()
        guard now.timeIntervalSince(lastLine) >= 0.2 || (total > 0 && done == total) else { return }
        lastLine = now
        let doneMB = Double(done) / 1_048_576
        let speed = doneMB / max(elapsed, 0.001)
        var line = String(format: "\r%@: %.1f MB", label, doneMB)
        if total > 0 {
            line += String(
                format: " / %.1f MB (%.0f%%)",
                Double(total) / 1_048_576, Double(done) / Double(total) * 100)
        }
        line += String(format: " @ %.1f MB/s   ", speed)
        print(line, terminator: "")
        fflush(stdout)
    }

    func finishLine() { print() }
}

func sha256(ofFile path: String) throws -> String {
    guard let fh = FileHandle(forReadingAtPath: path) else {
        throw SpikeError.io("cannot open \(path) for hashing")
    }
    defer { try? fh.close() }
    var hasher = SHA256()
    while true {
        let chunk = try autoreleasepool { try fh.read(upToCount: 4 << 20) }
        guard let chunk, !chunk.isEmpty else { break }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Writes `megabytes` MiB of deterministic xorshift64 noise — incompressible
/// enough to keep transfer numbers honest.
func makeTestFile(path: String, megabytes: Int) throws {
    print("writing \(megabytes) MB test file to \(path)")
    guard FileManager.default.createFile(atPath: path, contents: nil),
          let fh = FileHandle(forWritingAtPath: path) else {
        throw SpikeError.io("cannot create \(path)")
    }
    defer { try? fh.close() }
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    var words = [UInt64](repeating: 0, count: 131_072) // 1 MiB per block
    for block in 0..<megabytes {
        for i in words.indices {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            words[i] = state
        }
        try words.withUnsafeBytes { raw in
            try autoreleasepool {
                try fh.write(contentsOf: Data(bytes: raw.baseAddress!, count: raw.count))
            }
        }
        if (block + 1) % 100 == 0 || block + 1 == megabytes {
            print("  \(block + 1)/\(megabytes) MB")
        }
    }
}

// MARK: - check command

struct CheckConfig {
    var host: String
    var port: UInt32
    var user: String
    var password: String?
    var keyPath: String?
    var keyPassphrase: String?
    var listDir: String
    var remoteDir: String
    var bigFile: String?
    var sizeMB: Int
    var cancelAfterMB: Int
    var chunkKB: Int
    var acceptUnknown: Bool
}

enum StepStatus: String {
    case pass = "PASS"
    case fail = "FAIL"
    case warn = "WARN"
    case skip = "SKIP"
}

struct StepResult {
    let name: String
    let status: StepStatus
    let note: String
}

func runCheck(_ cfg: CheckConfig) -> Int32 {
    installSigintHandler()
    print("joey-spike check — libssh \(String(cString: ssh_version(0)))")
    print("target \(cfg.user)@\(cfg.host):\(cfg.port), remote dir \(cfg.remoteDir), list dir \(cfg.listDir)\n")

    var results: [StepResult] = []
    func record(_ name: String, _ status: StepStatus, _ note: String = "") {
        results.append(StepResult(name: name, status: status, note: note))
        print("[\(status.rawValue)] \(name)\(note.isEmpty ? "" : " — \(note)")")
    }
    func summary() -> Int32 {
        print("\n== summary ==")
        for r in results {
            print("  [\(r.status.rawValue)] \(r.name)\(r.note.isEmpty ? "" : " — \(r.note)")")
        }
        if gInterrupted != 0 {
            print("RESULT: INTERRUPTED (Ctrl-C — cancel path worked if no FAIL above)")
            return 130
        }
        let failed = results.contains { $0.status == .fail }
        print(failed ? "RESULT: FAIL" : "RESULT: PASS")
        return failed ? 1 : 0
    }

    let policy: SpikeSSHEngine.HostKeyPolicy = cfg.acceptUnknown ? .acceptUnknown : .strict
    let chunk = cfg.chunkKB << 10

    // 1+2. Auth matrix: verify every provided method; keep one session for the rest
    // (prefer the key session — ed25519 is the ticket's named requirement).
    var engine: SpikeSSHEngine?
    defer { engine?.disconnect() }

    if let password = cfg.password {
        let e = SpikeSSHEngine(host: cfg.host, port: cfg.port, user: cfg.user)
        do {
            let fp = try e.connect(auth: .password(password), hostKeyPolicy: policy)
            record("password auth", .pass, fp)
            engine = e
        } catch {
            record("password auth", .fail, "\(error)")
            e.disconnect()
        }
    } else {
        record("password auth", .skip, "no --password-env / --ask-password given")
    }

    if let keyPath = cfg.keyPath {
        let e = SpikeSSHEngine(host: cfg.host, port: cfg.port, user: cfg.user)
        do {
            let fp = try e.connect(
                auth: .privateKey(path: keyPath, passphrase: cfg.keyPassphrase),
                hostKeyPolicy: policy)
            record("key auth (\(keyPath))", .pass, fp)
            engine?.disconnect()
            engine = e
        } catch {
            record("key auth (\(keyPath))", .fail, "\(error)")
            e.disconnect()
        }
    } else {
        record("key auth", .skip, "no --key given")
    }

    guard let engine else {
        record("remaining checks", .skip, "no usable session")
        return summary()
    }

    // 3. Directory listing — must come back complete, ticket wants >100 entries.
    do {
        let entries = try engine.listDirectory(cfg.listDir)
            .filter { $0.name != "." && $0.name != ".." }
        if entries.count > 100 {
            record("list \(cfg.listDir)", .pass, "\(entries.count) entries, no truncation")
        } else {
            record(
                "list \(cfg.listDir)", .warn,
                "only \(entries.count) entries — ticket wants >100; point --list-dir at a bigger directory")
        }
    } catch {
        record("list \(cfg.listDir)", .fail, "\(error)")
    }

    // Prepare the big local file.
    let localBig: String
    if let provided = cfg.bigFile {
        localBig = provided
    } else {
        localBig = NSTemporaryDirectory() + "joey-spike-src-\(cfg.sizeMB)mb.bin"
    }
    let wantedBytes = UInt64(cfg.sizeMB) << 20
    do {
        if cfg.bigFile != nil {
            guard localFileSize(localBig) != nil else {
                throw SpikeError.io("--big-file \(localBig) does not exist")
            }
        } else if localFileSize(localBig) != wantedBytes {
            try makeTestFile(path: localBig, megabytes: cfg.sizeMB)
        } else {
            print("reusing test file \(localBig)")
        }
    } catch {
        record("prepare \(cfg.sizeMB)MB test file", .fail, "\(error)")
        return summary()
    }
    guard let srcSize = localFileSize(localBig) else {
        record("prepare test file", .fail, "cannot stat \(localBig)")
        return summary()
    }
    print("hashing \(localBig)…")
    guard let srcHash = try? sha256(ofFile: localBig) else {
        record("hash test file", .fail, "cannot hash \(localBig)")
        return summary()
    }

    // 4. Upload with byte-level progress.
    let remoteUpload = cfg.remoteDir + "/joey-spike-upload.bin"
    var uploadOK = false
    do {
        let pp = ProgressPrinter("upload")
        try engine.upload(localPath: localBig, remotePath: remoteUpload, chunkSize: chunk) { done, total in
            pp.update(done: done, total: total)
            return gInterrupted == 0
        }
        pp.finishLine()
        let remoteSize = try engine.stat(remoteUpload)
        guard remoteSize == srcSize else {
            throw SpikeError.sftp("remote size \(remoteSize) != local \(srcSize)")
        }
        let speed = Double(srcSize) / 1_048_576 / max(pp.elapsed, 0.001)
        record("upload \(srcSize >> 20)MB", .pass, String(format: "%.1f MB/s", speed))
        uploadOK = true
    } catch SpikeError.cancelled {
        print()
        record("upload", .fail, "interrupted")
        return summary()
    } catch {
        print()
        record("upload", .fail, "\(error)")
    }

    // 5. Clean cancel: upload again, cancel mid-flight, session must stay usable.
    if uploadOK {
        let remoteCancel = cfg.remoteDir + "/joey-spike-cancel.bin"
        let cancelLimit = min(UInt64(cfg.cancelAfterMB) << 20, wantedBytes / 2)
        var cancelIssued: Date?
        do {
            let pp = ProgressPrinter("cancel-test upload")
            try engine.upload(localPath: localBig, remotePath: remoteCancel, chunkSize: chunk) { done, total in
                pp.update(done: done, total: total)
                if gInterrupted != 0 { return false }
                if done >= cancelLimit {
                    if cancelIssued == nil { cancelIssued = Date() }
                    return false
                }
                return true
            }
            print()
            record("clean cancel", .fail, "transfer completed without honoring cancel")
        } catch SpikeError.cancelled {
            print()
            if gInterrupted != 0 { return summary() }
            let ms = cancelIssued.map { Date().timeIntervalSince($0) * 1000 } ?? 0
            do {
                _ = try engine.listDirectory(cfg.remoteDir)
                try? engine.removeFile(remoteCancel)
                record(
                    "clean cancel", .pass,
                    String(format: "stopped in %.0f ms at %ld MB, session still usable", ms, Int(cancelLimit >> 20)))
            } catch {
                record("clean cancel", .fail, "cancelled, but session unusable afterwards: \(error)")
            }
        } catch {
            print()
            record("clean cancel", .fail, "\(error)")
        }
    } else {
        record("clean cancel", .skip, "upload failed")
    }

    // 6. Download + integrity check.
    if uploadOK {
        let localDown = NSTemporaryDirectory() + "joey-spike-download.bin"
        do {
            let pp = ProgressPrinter("download")
            try engine.download(remotePath: remoteUpload, localPath: localDown, chunkSize: chunk) { done, total in
                pp.update(done: done, total: total)
                return gInterrupted == 0
            }
            pp.finishLine()
            let speed = Double(srcSize) / 1_048_576 / max(pp.elapsed, 0.001)
            print("hashing downloaded file…")
            let downHash = try sha256(ofFile: localDown)
            if downHash == srcHash {
                record("download \(srcSize >> 20)MB + sha256", .pass, String(format: "%.1f MB/s, checksums match", speed))
            } else {
                record("download + sha256", .fail, "checksum mismatch: \(downHash) vs \(srcHash)")
            }
        } catch SpikeError.cancelled {
            print()
            record("download", .fail, "interrupted")
        } catch {
            print()
            record("download", .fail, "\(error)")
        }
        try? FileManager.default.removeItem(atPath: localDown)
        try? engine.removeFile(remoteUpload)
    } else {
        record("download + sha256", .skip, "upload failed")
    }

    return summary()
}

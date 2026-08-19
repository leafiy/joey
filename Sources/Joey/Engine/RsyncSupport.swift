import Foundation

/// rsync acceleration mechanics per docs/research/rsync-detect-and-install.md:
/// remote detection over one SSH exec, package-manager probe + non-interactive
/// install (sudo via `-S` on stdin, never a PTY), and the local rsync
/// invocation for key-auth hosts. Password-auth hosts never use rsync.
enum RsyncSupport {

    // MARK: - Remote detection

    enum RemoteState: Equatable {
        case present(banner: String)
        case missing
        case unknown(detail: String)
    }

    static let detectCommand =
        "sh -c 'command -v rsync >/dev/null 2>&1 && rsync --version 2>/dev/null | head -n 2'"

    static func parseDetection(_ result: ExecResult) -> RemoteState {
        switch result.exitStatus {
        case 0:
            let banner = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return banner.isEmpty ? .unknown(detail: "empty version banner") : .present(banner: banner)
        case 1, 127:
            return .missing
        default:
            return .unknown(detail: "exit \(result.exitStatus): \(result.stderr)")
        }
    }

    // MARK: - Remote install

    struct PackageManager {
        let probe: String
        let install: String
        let needsSudo: Bool
    }

    /// Probe order fixed by the research doc; first hit wins.
    static let packageManagers: [PackageManager] = [
        .init(probe: "apt-get",
              install: "DEBIAN_FRONTEND=noninteractive apt-get install -y rsync", needsSudo: true),
        .init(probe: "dnf", install: "dnf install -y rsync", needsSudo: true),
        .init(probe: "yum", install: "yum install -y rsync", needsSudo: true),
        .init(probe: "zypper", install: "zypper --non-interactive install rsync", needsSudo: true),
        .init(probe: "pacman", install: "pacman -S --noconfirm --needed rsync", needsSudo: true),
        .init(probe: "apk", install: "apk add rsync", needsSudo: true),
        .init(probe: "brew", install: "brew install rsync", needsSudo: false),
    ]

    static let probeCommand =
        "sh -c 'for p in apt-get dnf yum zypper pacman apk brew; do command -v $p >/dev/null 2>&1 && echo $p && break; done'"

    struct InstallPlan {
        let manager: PackageManager
        /// The command joey will run, shown verbatim in the UI before running.
        let display: String
        /// nil = run directly; non-nil = sudo required, password fed to stdin.
        let sudoCommand: String?
    }

    /// Builds the install plan from probe output plus the remote uid and a
    /// NOPASSWD check (`sudo -n true`). Returns nil when no manager was found.
    static func installPlan(
        managerName: String, isRoot: Bool, hasNopasswdSudo: Bool
    ) -> InstallPlan? {
        guard let pm = packageManagers.first(where: { $0.probe == managerName }) else { return nil }
        if !pm.needsSudo || isRoot {
            return InstallPlan(manager: pm, display: pm.install, sudoCommand: nil)
        }
        if hasNopasswdSudo {
            return InstallPlan(
                manager: pm, display: "sudo \(pm.install)",
                sudoCommand: nil)
        }
        return InstallPlan(
            manager: pm, display: "sudo \(pm.install)",
            sudoCommand: "sudo -S -p '' sh -c '\(pm.install)'")
    }

    /// The directly runnable command for plans that don't need a fed password.
    static func directCommand(for plan: InstallPlan, isRoot: Bool) -> String {
        if plan.sudoCommand != nil { return plan.sudoCommand! }
        if !plan.manager.needsSudo || isRoot { return plan.manager.install }
        return "sudo -n \(plan.manager.install)"
    }

    // MARK: - Local binary

    struct LocalRsync {
        let path: String
        /// True when the binary supports `--info=progress2` (rsync ≥ 3.1).
        let modern: Bool
    }

    /// Homebrew rsync first (both prefixes), then the stock binary.
    static func findLocalRsync() -> LocalRsync? {
        let candidates = ["/opt/homebrew/bin/rsync", "/usr/local/bin/rsync", "/usr/bin/rsync"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return LocalRsync(path: path, modern: isModernRsync(path))
        }
        return nil
    }

    static func isModernRsync(_ path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let banner = String(decoding: data, as: UTF8.self)
        // GNU rsync prints "rsync  version 3.x.y"; openrsync and 2.6.9 never
        // support --info=progress2.
        guard let match = banner.range(of: #"rsync\s+version\s+(\d+)\.(\d+)"#, options: .regularExpression)
        else { return false }
        let parts = banner[match].split(whereSeparator: { !$0.isNumber && $0 != "." }).last?
            .split(separator: ".") ?? []
        guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else {
            return false
        }
        return major > 3 || (major == 3 && minor >= 1)
    }

    // MARK: - Transfer invocation (key auth only)

    /// Escapes a remote path for the remote shell rsync passes it through.
    static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func uploadArguments(
        localPath: String, record: HostRecord, keyPath: String,
        remoteDirectory: String, modern: Bool
    ) -> [String] {
        var args = ["-rlpt", "-z", "--partial", "--progress"]
        if modern { args += ["--info=progress2", "--no-inc-recursive"] }
        let ssh = "ssh -p \(record.port) -i \(keyPath) "
            + "-o BatchMode=yes -o IdentitiesOnly=yes "
            + "-o StrictHostKeyChecking=accept-new "
            + "-o ConnectTimeout=10 -o ServerAliveInterval=15"
        let host = record.host.contains(":") ? "[\(record.host)]" : record.host
        let dir = remoteDirectory.hasSuffix("/") ? remoteDirectory : remoteDirectory + "/"
        args += ["-e", ssh, localPath, "\(record.username)@\(host):\(shellQuote(dir))"]
        return args
    }

    /// Parses one `\r`/`\n`-separated progress chunk; returns 0…1 when a
    /// percentage is present. Works for both progress2 and per-file `--progress`.
    static func parseProgressPercent(_ line: String) -> Double? {
        guard let range = line.range(of: #"(\d+)%"#, options: .regularExpression) else { return nil }
        let digits = line[range].dropLast()
        guard let value = Int(digits) else { return nil }
        return Double(value) / 100.0
    }
}

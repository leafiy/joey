import Foundation

// joey-spike — ticket 03: minimal proof that the libssh stack covers joey's
// core path on macOS. `check` runs the whole ticket checklist; ls/upload/
// download exist for poking at individual pieces while debugging.

struct ArgumentError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

struct ParsedArgs {
    var options: [String: String] = [:]
    var flags: Set<String> = []
    var positionals: [String] = []
}

let connectionOptionKeys: Set<String> = [
    "--host", "--port", "--user", "--password-env", "--key", "--key-passphrase-env",
]
let connectionFlagKeys: Set<String> = [
    "--ask-password", "--ask-key-passphrase", "--accept-unknown",
]

func parseArgs(_ argv: [String], optionKeys: Set<String>, flagKeys: Set<String>) throws -> ParsedArgs {
    var out = ParsedArgs()
    var i = 0
    while i < argv.count {
        let arg = argv[i]
        if flagKeys.contains(arg) {
            out.flags.insert(arg)
        } else if optionKeys.contains(arg) {
            i += 1
            guard i < argv.count else { throw ArgumentError("\(arg) needs a value") }
            out.options[arg] = argv[i]
        } else if arg.hasPrefix("--") {
            throw ArgumentError("unknown option \(arg)")
        } else {
            out.positionals.append(arg)
        }
        i += 1
    }
    return out
}

func promptSecret(_ prompt: String) -> String {
    print(prompt, terminator: "")
    fflush(stdout)
    var old = termios()
    tcgetattr(STDIN_FILENO, &old)
    var noEcho = old
    noEcho.c_lflag &= ~tcflag_t(ECHO)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &noEcho)
    defer {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &old)
        print()
    }
    return readLine() ?? ""
}

func envValue(_ name: String) throws -> String {
    guard let value = ProcessInfo.processInfo.environment[name] else {
        throw ArgumentError("environment variable \(name) is not set")
    }
    return value
}

func expandPath(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

func resolvePassword(_ p: ParsedArgs) throws -> String? {
    if let env = p.options["--password-env"] { return try envValue(env) }
    if p.flags.contains("--ask-password") { return promptSecret("password: ") }
    return nil
}

func resolveKeyPassphrase(_ p: ParsedArgs) throws -> String? {
    if let env = p.options["--key-passphrase-env"] { return try envValue(env) }
    if p.flags.contains("--ask-key-passphrase") { return promptSecret("key passphrase: ") }
    return nil
}

func parsePort(_ raw: String?) throws -> UInt32 {
    guard let raw else { return 22 }
    guard let port = UInt32(raw), (1...65535).contains(port) else {
        throw ArgumentError("invalid --port \(raw)")
    }
    return port
}

func parsePositiveInt(_ p: ParsedArgs, _ key: String, default def: Int) throws -> Int {
    guard let raw = p.options[key] else { return def }
    guard let value = Int(raw), value > 0 else { throw ArgumentError("invalid \(key) \(raw)") }
    return value
}

/// Shared connection setup for the single-auth commands (ls/upload/download).
func makeEngine(_ p: ParsedArgs) throws -> (SpikeSSHEngine, SpikeSSHEngine.Auth, SpikeSSHEngine.HostKeyPolicy) {
    guard let host = p.options["--host"] else { throw ArgumentError("--host is required") }
    guard let user = p.options["--user"] else { throw ArgumentError("--user is required") }
    let engine = SpikeSSHEngine(host: host, port: try parsePort(p.options["--port"]), user: user)
    let auth: SpikeSSHEngine.Auth
    if let keyPath = p.options["--key"] {
        auth = .privateKey(path: expandPath(keyPath), passphrase: try resolveKeyPassphrase(p))
    } else if let password = try resolvePassword(p) {
        auth = .password(password)
    } else {
        throw ArgumentError("need --key or --password-env/--ask-password")
    }
    let policy: SpikeSSHEngine.HostKeyPolicy =
        p.flags.contains("--accept-unknown") ? .acceptUnknown : .strict
    return (engine, auth, policy)
}

func runCheckCommand(_ argv: [String]) throws -> Int32 {
    let optionKeys = connectionOptionKeys.union([
        "--list-dir", "--remote-dir", "--big-file", "--size-mb", "--cancel-after-mb", "--chunk-kb",
    ])
    let p = try parseArgs(argv, optionKeys: optionKeys, flagKeys: connectionFlagKeys)
    guard let host = p.options["--host"] else { throw ArgumentError("--host is required") }
    guard let user = p.options["--user"] else { throw ArgumentError("--user is required") }

    let password = try resolvePassword(p)
    let keyPath = p.options["--key"].map(expandPath)
    guard password != nil || keyPath != nil else {
        throw ArgumentError("need at least one auth method: --password-env/--ask-password and/or --key")
    }

    let cfg = CheckConfig(
        host: host,
        port: try parsePort(p.options["--port"]),
        user: user,
        password: password,
        keyPath: keyPath,
        keyPassphrase: keyPath != nil ? try resolveKeyPassphrase(p) : nil,
        listDir: p.options["--list-dir"] ?? "/usr/bin",
        remoteDir: p.options["--remote-dir"] ?? "/tmp",
        bigFile: p.options["--big-file"].map(expandPath),
        sizeMB: try parsePositiveInt(p, "--size-mb", default: 500),
        cancelAfterMB: try parsePositiveInt(p, "--cancel-after-mb", default: 64),
        chunkKB: try parsePositiveInt(p, "--chunk-kb", default: 128),
        acceptUnknown: p.flags.contains("--accept-unknown"))
    return runCheck(cfg)
}

func runMakeTestFile(_ argv: [String]) throws -> Int32 {
    let p = try parseArgs(argv, optionKeys: ["--size-mb"], flagKeys: [])
    guard p.positionals.count == 1 else {
        throw ArgumentError("usage: joey-spike make-test-file <path> [--size-mb 500]")
    }
    try makeTestFile(
        path: expandPath(p.positionals[0]),
        megabytes: try parsePositiveInt(p, "--size-mb", default: 500))
    return 0
}

func runLs(_ argv: [String]) throws -> Int32 {
    let p = try parseArgs(argv, optionKeys: connectionOptionKeys, flagKeys: connectionFlagKeys)
    guard p.positionals.count == 1 else {
        throw ArgumentError("usage: joey-spike ls <connection options> <remote-path>")
    }
    let (engine, auth, policy) = try makeEngine(p)
    defer { engine.disconnect() }
    let fingerprint = try engine.connect(auth: auth, hostKeyPolicy: policy)
    print("connected to \(engine.host) (\(fingerprint))")
    let entries = try engine.listDirectory(p.positionals[0])
        .filter { $0.name != "." && $0.name != ".." }
        .sorted { $0.name < $1.name }
    for entry in entries {
        let kind = entry.isDirectory ? "d" : "-"
        print("\(kind) \(String(format: "%12llu", entry.size)) \(entry.name)")
    }
    print("\(entries.count) entries")
    return 0
}

func runTransfer(_ argv: [String], upload: Bool) throws -> Int32 {
    let p = try parseArgs(
        argv, optionKeys: connectionOptionKeys.union(["--chunk-kb"]), flagKeys: connectionFlagKeys)
    guard p.positionals.count == 2 else {
        throw ArgumentError(
            upload
                ? "usage: joey-spike upload <connection options> <local-file> <remote-file>"
                : "usage: joey-spike download <connection options> <remote-file> <local-file>")
    }
    let chunk = try parsePositiveInt(p, "--chunk-kb", default: 128) << 10
    let (engine, auth, policy) = try makeEngine(p)
    defer { engine.disconnect() }
    installSigintHandler()
    let fingerprint = try engine.connect(auth: auth, hostKeyPolicy: policy)
    print("connected to \(engine.host) (\(fingerprint))")
    let pp = ProgressPrinter(upload ? "upload" : "download")
    let progress: (UInt64, UInt64) -> Bool = { done, total in
        pp.update(done: done, total: total)
        return gInterrupted == 0
    }
    do {
        if upload {
            try engine.upload(
                localPath: expandPath(p.positionals[0]), remotePath: p.positionals[1],
                chunkSize: chunk, progress: progress)
        } else {
            try engine.download(
                remotePath: p.positionals[0], localPath: expandPath(p.positionals[1]),
                chunkSize: chunk, progress: progress)
        }
        pp.finishLine()
        print("done")
        return 0
    } catch SpikeError.cancelled {
        pp.finishLine()
        print("cancelled")
        return 130
    }
}

func printUsage() {
    print("""
    joey-spike — SSH engine spike for joey (ticket 03)

    USAGE:
      joey-spike check <connection> [check options]     run the full ticket checklist
      joey-spike make-test-file <path> [--size-mb 500]  generate an incompressible test file
      joey-spike ls <connection> <remote-path>
      joey-spike upload <connection> <local-file> <remote-file>
      joey-spike download <connection> <remote-file> <local-file>

    CONNECTION:
      --host <host> --user <user> [--port 22] [--accept-unknown]
      auth (check tests every method given; other commands prefer --key):
        --password-env <VAR> | --ask-password
        --key <path> [--key-passphrase-env <VAR> | --ask-key-passphrase]

    CHECK OPTIONS:
      --list-dir <path>        remote dir for the >100-entries listing test (default /usr/bin)
      --remote-dir <path>      writable remote dir for transfer tests (default /tmp)
      --big-file <path>        use an existing local file instead of generating one
      --size-mb <n>            generated test file size (default 500)
      --cancel-after-mb <n>    cancel-test threshold (default 64)
      --chunk-kb <n>           transfer chunk size (default 128, clamped to server limits)

    Ctrl-C during any transfer exercises the clean-cancel path.
    """)
}

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else {
    printUsage()
    exit(2)
}
let rest = Array(argv.dropFirst())
do {
    switch command {
    case "check":
        exit(try runCheckCommand(rest))
    case "make-test-file":
        exit(try runMakeTestFile(rest))
    case "ls":
        exit(try runLs(rest))
    case "upload":
        exit(try runTransfer(rest, upload: true))
    case "download":
        exit(try runTransfer(rest, upload: false))
    case "help", "--help", "-h":
        printUsage()
        exit(0)
    default:
        throw ArgumentError("unknown command \(command); see joey-spike --help")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

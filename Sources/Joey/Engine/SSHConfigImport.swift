import Foundation

/// One-shot importer for `~/.ssh/config` basic fields (Host / HostName / User /
/// Port / IdentityFile). Wildcard host patterns, `Match` blocks, and `Include`
/// are ignored — this seeds Host Records, it does not emulate OpenSSH.
enum SSHConfigImport {

    struct ImportedHost {
        let name: String
        let host: String
        let username: String?
        let port: Int
        let identityFile: String?
    }

    static func defaultConfigPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/config")
    }

    static func importHosts(from path: String = defaultConfigPath()) -> [ImportedHost] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var results: [ImportedHost] = []

        var aliases: [String] = []
        var hostName: String?
        var user: String?
        var port: Int?
        var identityFile: String?

        func flush() {
            defer { aliases = []; hostName = nil; user = nil; port = nil; identityFile = nil }
            guard let alias = aliases.first(where: { !$0.contains("*") && !$0.contains("?") })
            else { return }
            results.append(ImportedHost(
                name: alias,
                host: hostName ?? alias,
                username: user,
                port: port ?? 22,
                identityFile: identityFile.map(expandTilde)))
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // "Key value" or "Key=value"; keys are case-insensitive.
            let parts = line.split(
                maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            switch key {
            case "host":
                flush()
                aliases = value.split(separator: " ").map(String.init)
            case "match":
                flush()
                aliases = []
            case "hostname" where !aliases.isEmpty:
                hostName = value
            case "user" where !aliases.isEmpty:
                user = value
            case "port" where !aliases.isEmpty:
                port = Int(value)
            case "identityfile" where !aliases.isEmpty:
                if identityFile == nil { identityFile = value }
            default:
                break
            }
        }
        flush()
        return results
    }

    private static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

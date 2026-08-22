import Foundation

/// Translates engine diagnostics into short, actionable text for the panel.
/// Low-level details stay inside the engine for troubleshooting and never
/// reach the user-facing error banner.
enum UserFacingError {
    enum Operation: Equatable {
        case browse
        case createFolder
        case rename
        case delete
        case upload
        case download
        case rsyncCheck
        case rsyncInstall
    }

    static func message(for error: Error, during operation: Operation) -> String {
        guard let error = error as? SSHEngineError else {
            return fallback(for: operation)
        }

        switch error {
        case .session(let detail):
            return connectionMessage(for: detail)
        case .auth:
            return L("Couldn’t sign in. Check the username and authentication details, then try again.")
        case .hostKey(let detail):
            if detail.lowercased().contains("changed") {
                return L("The server’s identity changed. Verify the server and update its saved key before reconnecting.")
            }
            return L("Couldn’t verify the server’s identity. Check the saved server key and try again.")
        case .sftp(let detail):
            return sftpMessage(for: detail, operation: operation)
        case .io:
            return operation == .download
                ? L("Couldn’t download this item. Check your access and available space on this Mac.")
                : fallback(for: operation)
        case .exec(let detail):
            return diagnosticMessage(for: detail, during: operation)
        case .cancelled:
            return L("The operation was cancelled.")
        }
    }

    static func message(forDiagnostic detail: String, during operation: Operation) -> String {
        diagnosticMessage(for: detail, during: operation)
    }

    private static func sftpMessage(for detail: String, operation: Operation) -> String {
        let normalized = detail.lowercased()

        // Some Windows SFTP servers report a protected-directory open as the
        // generic SSH_FX_BAD_MESSAGE (code 5). Treat it as an access failure
        // for the browsing path, which gives the user a useful next step.
        if isPermissionFailure(normalized)
            || (operation == .browse && normalized.contains("sftp code 5")) {
            return permissionMessage(for: operation)
        }
        if contains(normalized, anyOf: ["no such file", "no such path", "not found", "sftp code 2", "sftp code 10"]) {
            return operation == .browse
                ? L("This folder can’t be found. It may have been moved or deleted.")
                : L("This item can’t be found. It may have been moved or deleted.")
        }
        if contains(normalized, anyOf: ["already exists", "file exists", "sftp code 11"]) {
            return L("An item with this name already exists.")
        }
        if contains(normalized, anyOf: ["no space", "disk full", "quota", "sftp code 14", "sftp code 15"]) {
            return L("There isn’t enough storage space to complete this operation.")
        }
        if contains(normalized, anyOf: ["unsupported", "not supported", "sftp code 8"]) {
            return L("The server doesn’t support this operation.")
        }
        if contains(normalized, anyOf: ["no connection", "connection lost", "sftp code 6", "sftp code 7"]) {
            return L("The connection to the server was lost. Try again.")
        }
        return fallback(for: operation)
    }

    private static func diagnosticMessage(for detail: String, during operation: Operation) -> String {
        let normalized = detail.lowercased()
        if isPermissionFailure(normalized) {
            return operation == .rsyncInstall
                ? L("You don’t have permission to install rsync.")
                : permissionMessage(for: operation)
        }
        return fallback(for: operation)
    }

    private static func connectionMessage(for detail: String) -> String {
        let normalized = detail.lowercased()
        if contains(normalized, anyOf: ["timed out", "timeout"]) {
            return L("The connection timed out. Check the host address and network, then try again.")
        }
        if contains(normalized, anyOf: ["connection lost", "connection reset", "broken pipe"]) {
            return L("The connection to the server was lost. Try again.")
        }
        return L("Couldn’t connect to the server. Check the host address and network, then try again.")
    }

    private static func permissionMessage(for operation: Operation) -> String {
        switch operation {
        case .browse:
            return L("You don’t have permission to open this folder.")
        case .createFolder:
            return L("You don’t have permission to create items in this folder.")
        case .rename:
            return L("You don’t have permission to rename this item.")
        case .delete:
            return L("You don’t have permission to delete this item.")
        case .upload:
            return L("You don’t have permission to upload to this folder.")
        case .download:
            return L("You don’t have permission to download this item.")
        case .rsyncCheck, .rsyncInstall:
            return L("You don’t have permission to install rsync.")
        }
    }

    private static func fallback(for operation: Operation) -> String {
        switch operation {
        case .browse:
            return L("Couldn’t open this folder. Check the path and your access permission.")
        case .createFolder:
            return L("Couldn’t create this folder. Check the name and your write permission.")
        case .rename:
            return L("Couldn’t rename this item. Check your write permission.")
        case .delete:
            return L("Couldn’t delete this item. It may be in use, protected, or a non-empty folder.")
        case .upload:
            return L("Couldn’t upload this item. Check the destination folder and your write permission.")
        case .download:
            return L("Couldn’t download this item. Check your access and available space on this Mac.")
        case .rsyncCheck:
            return L("Couldn’t check rsync on this host. Check the connection and try again.")
        case .rsyncInstall:
            return L("Couldn’t install rsync. Check the connection and try again.")
        }
    }

    private static func isPermissionFailure(_ detail: String) -> Bool {
        contains(detail, anyOf: [
            "permission denied",
            "access denied",
            "operation not permitted",
            "not in the sudoers",
            "not allowed to execute",
            "may not run sudo",
            "incorrect password",
            "authentication failure",
            "a password is required",
            "must be run as root",
            "sftp code 3",
            "sftp code 12",
        ])
    }

    private static func contains(_ detail: String, anyOf matches: [String]) -> Bool {
        matches.contains { detail.contains($0) }
    }
}

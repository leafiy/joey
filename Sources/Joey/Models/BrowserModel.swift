import Foundation

/// State of the panel's remote directory view (CONTEXT.md: Browser): current
/// path, lazily loaded entries, and remote mutation operations. Entries sort
/// folders first, then by name; visibility filtering and selection are
/// presentation concerns.
@MainActor
final class BrowserModel: ObservableObject {
    @Published private(set) var path: String = "/"
    @Published private(set) var entries: [RemoteEntry] = []
    @Published private(set) var isLoading = false
    @Published var operationError: TransferError?

    private(set) var session: HostSession?
    /// Called whenever the path changes, so the Last Browsed Directory can be
    /// persisted on the Host Record.
    var onPathChange: ((String) -> Void)?

    var breadcrumbs: [(name: String, path: String)] {
        Self.breadcrumbs(for: path)
    }

    /// Splits both POSIX and Windows remote paths into navigable ancestors.
    /// Keep the original separator because it is also what the SFTP server
    /// expects when a breadcrumb is opened.
    static func breadcrumbs(for path: String) -> [(name: String, path: String)] {
        if let drive = windowsDrive(in: path) {
            let separator: Character = path.contains("\\") ? "\\" : "/"
            let separatorString = String(separator)
            let components = path.dropFirst(2)
                .split(separator: separator, omittingEmptySubsequences: true)

            var accumulated = "\(drive)\(separatorString)"
            var crumbs: [(String, String)] = [(drive, accumulated)]
            for component in components {
                if !accumulated.hasSuffix(separatorString) {
                    accumulated += separatorString
                }
                accumulated += component
                crumbs.append((String(component), accumulated))
            }
            return crumbs
        }

        var crumbs: [(String, String)] = [("/", "/")]
        var acc = ""
        for part in path.split(separator: "/") {
            acc += "/\(part)"
            crumbs.append((String(part), acc))
        }
        return crumbs
    }

    private static func windowsDrive(in path: String) -> String? {
        guard path.count >= 2 else { return nil }
        let prefix = path.prefix(2)
        guard prefix.last == ":", prefix.first?.isLetter == true else { return nil }
        return String(prefix)
    }

    func activate(session: HostSession?, startPath: String?) {
        self.session = session
        entries = []
        operationError = nil
        guard session != nil else { return }
        Task { await open(startPath ?? "", resolveHome: startPath?.isEmpty != false) }
    }

    /// Navigates to `target` and reloads. With `resolveHome`, an empty target
    /// resolves to the remote home directory first.
    func open(_ target: String, resolveHome: Bool = false) async {
        guard let session else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            var destination = target
            if resolveHome || destination.isEmpty {
                destination = (try? await session.homeDirectory()) ?? "/"
            }
            let listed = try await session.listDirectory(destination)
            path = destination
            entries = sorted(listed)
            onPathChange?(destination)
        } catch {
            operationError = TransferError(
                fileName: lastComponent(target),
                message: UserFacingError.message(for: error, during: .browse))
        }
    }

    func refresh() async {
        await open(path)
    }

    func enter(_ entry: RemoteEntry) async {
        guard entry.isDirectory else { return }
        await open(joinRemote(path, entry.name))
    }

    // MARK: - Remote mutation operations

    func createFolder(named name: String) async {
        await perform(name, operation: .createFolder) { [self] in
            try await session?.createDirectory(joinRemote(path, name))
        }
    }

    func rename(_ entry: RemoteEntry, to newName: String) async {
        await perform(entry.name, operation: .rename) { [self] in
            try await session?.rename(joinRemote(path, entry.name), to: joinRemote(path, newName))
        }
    }

    func delete(_ entry: RemoteEntry) async {
        await perform(entry.name, operation: .delete) { [self] in
            try await session?.remove(entry, at: joinRemote(path, entry.name))
        }
    }

    private func perform(
        _ fileName: String,
        operation: UserFacingError.Operation,
        _ body: @escaping () async throws -> Void
    ) async {
        do {
            try await body()
            await refresh()
        } catch {
            operationError = TransferError(
                fileName: fileName,
                message: UserFacingError.message(for: error, during: operation))
        }
    }

    static func effectiveEntries(
        for clickedEntry: RemoteEntry,
        selection: Set<RemoteEntry.ID>,
        in entries: [RemoteEntry]
    ) -> [RemoteEntry] {
        guard selection.contains(clickedEntry.id) else { return [clickedEntry] }
        return entries.filter { selection.contains($0.id) }
    }

    private func sorted(_ list: [RemoteEntry]) -> [RemoteEntry] {
        list.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func lastComponent(_ p: String) -> String {
        p.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? p
    }
}

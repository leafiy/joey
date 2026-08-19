import Foundation

/// State of the panel's remote directory view (CONTEXT.md: Browser) for the
/// Active Host: current path, lazily loaded entries, and the three v1 file
/// operations. Sorting is fixed: folders first, then by name; dotfiles always
/// visible.
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
        var crumbs: [(String, String)] = [("/", "/")]
        var acc = ""
        for part in path.split(separator: "/") {
            acc += "/\(part)"
            crumbs.append((String(part), acc))
        }
        return crumbs
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
            operationError = TransferError(fileName: lastComponent(target), message: "\(error)")
        }
    }

    func refresh() async {
        await open(path)
    }

    func enter(_ entry: RemoteEntry) async {
        guard entry.isDirectory else { return }
        await open(joinRemote(path, entry.name))
    }

    // MARK: - File operations (v1: delete, rename, new folder — nothing else)

    func createFolder(named name: String) async {
        await perform(name) { [self] in
            try await session?.createDirectory(joinRemote(path, name))
        }
    }

    func rename(_ entry: RemoteEntry, to newName: String) async {
        await perform(entry.name) { [self] in
            try await session?.rename(joinRemote(path, entry.name), to: joinRemote(path, newName))
        }
    }

    func delete(_ entry: RemoteEntry) async {
        await perform(entry.name) { [self] in
            try await session?.remove(entry, at: joinRemote(path, entry.name))
        }
    }

    private func perform(_ fileName: String, _ body: @escaping () async throws -> Void) async {
        do {
            try await body()
            await refresh()
        } catch {
            operationError = TransferError(fileName: fileName, message: "\(error)")
        }
    }

    private func sorted(_ list: [RemoteEntry]) -> [RemoteEntry] {
        list.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func lastComponent(_ p: String) -> String {
        p.split(separator: "/").last.map(String.init) ?? p
    }
}

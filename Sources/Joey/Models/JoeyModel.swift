import AppKit
import Foundation
import LeafiyUI
import LeafiyUICore
import SwiftUI
import UniformTypeIdentifiers

/// Joey's central state: the settings document, per-host session cache,
/// Browser state, Transfers, and the two Icon Drop surfaces (Favorite Tray /
/// main panel).
enum RsyncHostStatus: Equatable {
    case checking
    case enabled(banner: String)
    case missing
    case unavailable(String)
    case failed(String)

    init(remoteState: RsyncSupport.RemoteState) {
        switch remoteState {
        case .present(let banner):
            self = .enabled(banner: banner)
        case .missing:
            self = .missing
        case .unknown(let detail):
            self = .failed(detail)
        }
    }

    var isMissing: Bool {
        if case .missing = self { return true }
        return false
    }
}

@MainActor
final class JoeyModel: ObservableObject {
    @Published private(set) var settings: AppSettings
    /// Mirrors whether the menu-bar panel content is on screen.
    @Published var panelVisible = false
    /// Non-nil while the rsync install sheet is up for the Active Host.
    @Published var rsyncInstall: RsyncInstallFlow?
    /// True when the Active Host is key-auth but its remote has no rsync —
    /// drives the panel's install hint strip.
    @Published private(set) var rsyncMissingOnActiveHost = false
    @Published private(set) var rsyncStatuses: [UUID: RsyncHostStatus] = [:]

    let transfers = TransferManager()
    let browser = BrowserModel()
    private(set) lazy var favoriteTray = FavoriteTrayController(model: self)

    private let settingsStore: SettingsStore
    private var sessions: [UUID: HostSession] = [:]

    init(store: SettingsStore = SettingsStore()) {
        settingsStore = store
        settings = store.load()
        browser.onPathChange = { [weak self] path in
            self?.recordLastBrowsedDirectory(path)
        }
    }

    // MARK: - Settings

    var language: AppLanguage { settings.selectedAppLanguage }

    func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        var next = settings
        mutate(&next)
        next = next.normalized()
        guard next != settings else { return }
        let previous = settings
        settings = next
        try? settingsStore.save(next)

        for host in next.hosts {
            if let old = previous.hosts.first(where: { $0.id == host.id }),
               !old.connectionEquals(host) {
                sessions[host.id]?.disconnect()
                sessions[host.id] = nil
                transfers.invalidateRsyncState(hostID: host.id)
                rsyncStatuses[host.id] = nil
            }
        }
        for removed in previous.hosts.map(\.id) where !next.hosts.contains(where: { $0.id == removed }) {
            sessions[removed]?.disconnect()
            sessions[removed] = nil
            transfers.invalidateRsyncState(hostID: removed)
            rsyncStatuses[removed] = nil
        }

        let activeChanged = next.activeHostID != previous.activeHostID
        let activeConnectionChanged = zip(previous.activeHost, next.activeHost)
            .map { !$0.0.connectionEquals($0.1) }
            ?? (previous.activeHost != nil || next.activeHost != nil)
        if activeChanged || activeConnectionChanged {
            activateBrowser()
        }
    }

    func setActiveHost(_ id: UUID) {
        updateSettings { $0.activeHostID = id }
    }

    private func recordLastBrowsedDirectory(_ path: String) {
        guard let activeID = settings.activeHostID else { return }
        updateSettings { settings in
            if let index = settings.hosts.firstIndex(where: { $0.id == activeID }) {
                settings.hosts[index].lastBrowsedDirectory = path
            }
        }
    }

    // MARK: - Sessions

    func session(for record: HostRecord) -> HostSession {
        if let cached = sessions[record.id], cached.record.connectionEquals(record) {
            return cached
        }
        sessions[record.id]?.disconnect()
        let fresh = HostSession(record: record)
        sessions[record.id] = fresh
        return fresh
    }

    var activeSession: HostSession? {
        guard let host = settings.activeHost, host.isComplete else { return nil }
        return session(for: host)
    }

    /// Points the Browser at the Active Host; call once at launch and after
    /// any change of Active Host or its connection fields.
    func activateBrowser() {
        guard let host = settings.activeHost, host.isComplete else {
            browser.activate(session: nil, startPath: nil)
            rsyncMissingOnActiveHost = false
            return
        }
        let session = session(for: host)
        browser.activate(session: session, startPath: host.browserStartDirectory)
        refreshRsyncHint(session: session)
    }

    // MARK: - Uploads

    /// Panel Drop / Icon Drop entry point. Empty `directory` resolves to the
    /// remote home first.
    func upload(_ urls: [URL], to directory: String, host: HostRecord) {
        guard host.isComplete, !urls.isEmpty else { return }
        let session = session(for: host)
        Task {
            var destination = directory
            if destination.isEmpty {
                destination = (try? await session.homeDirectory()) ?? "/"
            }
            await transfers.upload(urls: urls, to: destination, session: session)
            if browser.session === session, browser.path == destination {
                await browser.refresh()
            }
        }
    }

    func panelDrop(_ urls: [URL], into directory: String) {
        guard let host = settings.activeHost else {
            browser.operationError = TransferError(
                fileName: urls.first?.lastPathComponent ?? L("Drop files here to upload"),
                message: L("Configure a host before uploading.")
            )
            return
        }
        guard host.isComplete else {
            browser.operationError = TransferError(
                fileName: urls.first?.lastPathComponent ?? L("Drop files here to upload"),
                message: L("Complete host authentication before uploading.")
            )
            return
        }
        upload(urls, to: directory, host: host)
    }

    // MARK: - Icon Drop (ticket 08)

    /// Drag hovers the menu-bar icon: favorite Hosts → Favorite Tray; none →
    /// the main panel, so the drop can land in the Browser.
    func iconDragChanged(_ inside: Bool) {
        if inside {
            if settings.favoriteHosts.isEmpty {
                openPanelForDrop()
            } else {
                favoriteTray.show()
            }
        } else {
            favoriteTray.scheduleHide()
        }
    }

    /// Files released on the icon itself (not on a tray row or in the panel):
    /// first favorite Host when one exists, else the Active Host's Last
    /// Browsed Directory.
    func iconDrop(_ urls: [URL]) {
        favoriteTray.hide()
        if let host = settings.favoriteHosts.first {
            upload(urls, to: host.favoriteDirectory, host: host)
        } else if let host = settings.activeHost, host.isComplete {
            upload(urls, to: host.lastBrowsedDirectory, host: host)
        }
    }

    func favoriteDrop(_ urls: [URL], host: HostRecord) {
        favoriteTray.hide()
        upload(urls, to: host.favoriteDirectory, host: host)
    }

    private func openPanelForDrop() {
        guard !panelIsOpen else { return }
        LeafiyMenuBarDropTarget.performStatusItemClick()
    }

    private var panelIsOpen: Bool {
        if panelVisible { return true }
        return NSApp.windows.contains { $0.isVisible && $0.className.contains("MenuBarExtra") }
    }

    // MARK: - Drag-out

    func dragOutPromise(for entry: RemoteEntry) -> LeafiyFilePromise? {
        guard !entry.isDirectory, let session = browser.session else { return nil }
        let remotePath = joinRemote(browser.path, entry.name)
        let transfers = transfers
        let contentType = UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
        return LeafiyFilePromise(filename: entry.name, contentType: contentType) {
            destination, progress in
            try await transfers.download(
                remotePath: remotePath, fileName: entry.name, to: destination,
                session: session, progress: progress)
        }
    }

    // MARK: - rsync detect & install

    func rsyncStatus(for hostID: UUID) -> RsyncHostStatus {
        if let status = rsyncStatuses[hostID] { return status }
        guard let host = settings.hosts.first(where: { $0.id == hostID }) else {
            return .unavailable(L("Host not found."))
        }
        if !host.isComplete {
            return .unavailable(L("Complete the host configuration to check rsync."))
        }
        if !host.supportsRsync {
            return .unavailable(L("Private key authentication is required for rsync acceleration."))
        }
        if !transfers.isLocalRsyncAvailable {
            return .unavailable(L("No local rsync executable was found on this Mac."))
        }
        return .checking
    }

    func detectRsync(for hostID: UUID, force: Bool = false) async {
        guard let host = settings.hosts.first(where: { $0.id == hostID }) else {
            rsyncStatuses[hostID] = nil
            return
        }
        guard host.isComplete else {
            setRsyncStatus(
                .unavailable(L("Complete the host configuration to check rsync.")),
                for: hostID)
            return
        }
        guard host.supportsRsync else {
            setRsyncStatus(
                .unavailable(L("Private key authentication is required for rsync acceleration.")),
                for: hostID)
            return
        }
        guard transfers.isLocalRsyncAvailable else {
            setRsyncStatus(
                .unavailable(L("No local rsync executable was found on this Mac.")),
                for: hostID)
            return
        }
        if !force, let status = rsyncStatuses[hostID], status != .checking {
            setRsyncStatus(status, for: hostID)
            return
        }

        setRsyncStatus(.checking, for: hostID)
        let session = session(for: host)
        if force { transfers.invalidateRsyncState(hostID: hostID) }
        let remoteState = await transfers.remoteRsyncState(session: session)
        guard let current = settings.hosts.first(where: { $0.id == hostID }),
              current.connectionEquals(host) else { return }
        setRsyncStatus(RsyncHostStatus(remoteState: remoteState), for: hostID)
    }

    private func refreshRsyncHint(session: HostSession) {
        rsyncMissingOnActiveHost = false
        Task { await detectRsync(for: session.record.id) }
    }

    private func setRsyncStatus(_ status: RsyncHostStatus, for hostID: UUID) {
        rsyncStatuses[hostID] = status
        if settings.activeHost?.id == hostID {
            rsyncMissingOnActiveHost = status.isMissing
        }
    }

    func beginRsyncInstall(for hostID: UUID) {
        guard let host = settings.hosts.first(where: { $0.id == hostID }),
              host.isComplete, host.supportsRsync else { return }
        let flow = RsyncInstallFlow(session: session(for: host))
        rsyncInstall = flow
        Task { await flow.prepare() }
    }

    func finishRsyncInstall(success: Bool) {
        let hostID = rsyncInstall?.session.record.id
        rsyncInstall = nil
        guard success, let hostID else { return }
        transfers.invalidateRsyncState(hostID: hostID)
        Task { await detectRsync(for: hostID, force: true) }
    }
}

/// One run of the settings/panel "install rsync on the remote" flow: probes
/// the package manager and sudo situation, shows the exact command, runs it
/// (sudo password over stdin, never a PTY), and reports the outcome.
@MainActor
final class RsyncInstallFlow: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case probing
        case ready
        case needsPassword
        case running
        case failed(String)
        case succeeded
        case unavailable(String)
    }

    let id = UUID()
    let session: HostSession
    @Published var phase: Phase = .probing
    @Published var sudoPassword = ""
    private(set) var plan: RsyncSupport.InstallPlan?
    private(set) var isRoot = false

    init(session: HostSession) {
        self.session = session
    }

    var displayCommand: String { plan?.display ?? "" }

    func prepare() async {
        do {
            let probe = try await session.exec(RsyncSupport.probeCommand)
            let manager = probe.stdout
                .split(whereSeparator: \.isNewline).last.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard !manager.isEmpty else {
                phase = .unavailable(L("No supported package manager found on the remote."))
                return
            }
            let uid = try await session.exec("id -u")
            isRoot = uid.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
            let nopasswd = (try? await session.exec("sudo -n true"))?.exitStatus == 0
            guard let plan = RsyncSupport.installPlan(
                managerName: manager, isRoot: isRoot, hasNopasswdSudo: nopasswd) else {
                phase = .unavailable(L("No supported package manager found on the remote."))
                return
            }
            self.plan = plan
            if plan.sudoCommand == nil {
                phase = .ready
                await run()
            } else {
                phase = .needsPassword
            }
        } catch {
            phase = .unavailable("\(error)")
        }
    }

    func run() async {
        guard let plan else { return }
        phase = .running
        do {
            let result: ExecResult
            if let sudoCommand = plan.sudoCommand {
                result = try await session.exec(sudoCommand, stdin: sudoPassword + "\n")
            } else {
                result = try await session.exec(RsyncSupport.directCommand(for: plan, isRoot: isRoot))
            }
            sudoPassword = ""
            if result.exitStatus == 0 {
                let verify = try await session.exec(RsyncSupport.detectCommand)
                if case .present = RsyncSupport.parseDetection(verify) {
                    phase = .succeeded
                    return
                }
            }
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            phase = .failed(installFailureMessage(stderr.isEmpty ? stdout : stderr))
        } catch {
            sudoPassword = ""
            phase = .failed(installFailureMessage("\(error)"))
        }
    }

    private func installFailureMessage(_ detail: String) -> String {
        let fallback = detail.isEmpty ? L("Install failed.") : detail
        guard RsyncSupport.isPermissionFailure(detail) else { return fallback }
        let summary = L("Insufficient permission to install rsync.")
        return detail.isEmpty ? summary : "\(summary)\n\(detail)"
    }
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}

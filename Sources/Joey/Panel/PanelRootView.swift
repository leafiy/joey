import LeafiyUI
import LeafiyUICore
import SwiftUI

/// The menu-bar panel (ticket 05, variant A): Host Switcher toolbar,
/// breadcrumb row, inline Error Banner, single-column Browser with two-level
/// drop highlighting, row context menus, and the Gear Menu carrying the
/// family Menu Tail.
struct PanelRootView: View {
    @ObservedObject var model: JoeyModel
    @ObservedObject var browser: BrowserModel
    @ObservedObject var transfers: TransferManager

    @State private var listTargeted = false
    @State private var newFolderPrompt = false
    @State private var newFolderName = ""
    @State private var renameTarget: RemoteEntry?
    @State private var renameName = ""
    @State private var deleteTarget: RemoteEntry?

    init(model: JoeyModel) {
        self.model = model
        self.browser = model.browser
        self.transfers = model.transfers
    }

    private var hostConfigured: Bool {
        model.settings.activeHost?.isComplete == true
    }

    private var hasActiveHost: Bool {
        model.settings.activeHost != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if hostConfigured {
                breadcrumb
                Divider()
            }
            if let activityText {
                activityStrip(activityText)
                Divider()
            }
            if let banner = bannerText {
                errorStrip(banner)
                Divider()
            }
            if model.rsyncMissingOnActiveHost {
                rsyncHint
                Divider()
            }
            content
        }
        .frame(width: 360, height: 520)
        .onAppear {
            model.panelVisible = true
            if browser.session == nil { model.activateBrowser() }
        }
        .onDisappear { model.panelVisible = false }
        .alert(L("New Folder"), isPresented: $newFolderPrompt) {
            TextField(L("Folder name"), text: $newFolderName)
            Button(L("Create")) {
                let name = newFolderName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                Task { await browser.createFolder(named: name) }
            }
            Button(L("Cancel"), role: .cancel) {}
        }
        .alert(L("Rename"), isPresented: renamePresented) {
            TextField(L("New name"), text: $renameName)
            Button(L("Rename")) {
                let name = renameName.trimmingCharacters(in: .whitespaces)
                guard let target = renameTarget, !name.isEmpty, name != target.name else { return }
                Task { await browser.rename(target, to: name) }
            }
            Button(L("Cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            deleteQuestion,
            isPresented: deletePresented,
            titleVisibility: .visible
        ) {
            Button(L("Delete"), role: .destructive) {
                guard let target = deleteTarget else { return }
                Task { await browser.delete(target) }
            }
        } message: {
            Text(L("The remote file is deleted immediately. This cannot be undone."))
        }
        .sheet(item: $model.rsyncInstall) { flow in
            RsyncInstallSheet(flow: flow, model: model)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            hostSwitcher
            Spacer()
            Button {
                newFolderName = L("untitled folder")
                newFolderPrompt = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .help(L("New Folder"))
            .disabled(!hostConfigured)
            gearMenu
        }
        .padding(.horizontal, LeafiyDesign.Spacing.m)
        .padding(.vertical, LeafiyDesign.Spacing.s)
    }

    private var hostSwitcher: some View {
        Menu {
            ForEach(model.settings.hosts) { host in
                Button {
                    model.setActiveHost(host.id)
                } label: {
                    if host.id == model.settings.activeHost?.id {
                        Label(host.displayName, systemImage: "checkmark")
                    } else {
                        Text(host.displayName)
                    }
                }
            }
            if !model.settings.hosts.isEmpty {
                Divider()
            }
            Button(L("Configure Hosts…")) { LeafiySettingsWindow.open() }
        } label: {
            HStack(spacing: LeafiyDesign.Spacing.xs) {
                Circle()
                    .fill(hostConfigured ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(model.settings.activeHost?.displayName ?? L("No Host"))
                    .lineLimit(1)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.accessoryBar)
        .fixedSize()
    }

    /// Gear Menu (joey ADR-0002): the family Menu Tail lives here because the
    /// panel replaces the standard pull-down menu.
    private var gearMenu: some View {
        Menu {
            LeafiyFamilyMenu(language: model.language) {
                Toggle(L("Show Hidden Files"), isOn: showHiddenFilesBinding)
                Button(L("Refresh")) {
                    Task { await browser.refresh() }
                }
                .disabled(!hostConfigured)
            }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
    }

    // MARK: - Breadcrumb

    private var breadcrumb: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LeafiyDesign.Spacing.xs) {
                    ForEach(Array(browser.breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.compact.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Button(crumb.name) {
                            Task { await browser.open(crumb.path) }
                        }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(
                            index == browser.breadcrumbs.count - 1
                                ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
                        )
                    }
                }
                .padding(.horizontal, LeafiyDesign.Spacing.m)
                .padding(.vertical, LeafiyDesign.Spacing.s)
            }
        }
    }

    private var showHiddenFilesBinding: Binding<Bool> {
        Binding(
            get: { model.settings.showHiddenFiles },
            set: { show in model.updateSettings { $0.showHiddenFiles = show } }
        )
    }

    private var hasVisibleEntries: Bool {
        model.settings.showHiddenFiles
            ? !browser.entries.isEmpty
            : browser.entries.contains { !$0.name.hasPrefix(".") }
    }

    private var activityText: String? {
        if transfers.activeCount > 0 { return L("Copying…") }
        if browser.isLoading { return L("Listing directory…") }
        return nil
    }

    private func activityStrip(_ text: String) -> some View {
        HStack(spacing: LeafiyDesign.Spacing.s) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, LeafiyDesign.Spacing.m)
        .padding(.vertical, LeafiyDesign.Spacing.xs)
    }

    // MARK: - Error Banner

    private var bannerText: String? {
        if let error = transfers.lastError {
            return "\(error.fileName) — \(error.message)"
        }
        if let error = browser.operationError {
            return "\(error.fileName) — \(error.message)"
        }
        return nil
    }

    private func errorStrip(_ text: String) -> some View {
        HStack(spacing: LeafiyDesign.Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(text)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button {
                transfers.clearError()
                browser.operationError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, LeafiyDesign.Spacing.m)
        .padding(.vertical, LeafiyDesign.Spacing.s)
        .background(Color.red.opacity(0.1))
    }

    private var rsyncHint: some View {
        HStack(spacing: LeafiyDesign.Spacing.s) {
            Image(systemName: "bolt.badge.clock")
                .foregroundStyle(.secondary)
            Text(L("rsync not found on this host — transfers use sftp."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(L("Install…")) {
                if let hostID = model.settings.activeHost?.id {
                    model.beginRsyncInstall(for: hostID)
                }
            }
                .font(.caption)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, LeafiyDesign.Spacing.m)
        .padding(.vertical, LeafiyDesign.Spacing.s)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !hostConfigured {
            VStack(spacing: LeafiyDesign.Spacing.m) {
                EmptyStateView(
                    systemImage: hasActiveHost ? "lock.slash" : "server.rack",
                    title: L(hasActiveHost ? "Host setup incomplete" : "No host configured"),
                    subtitle: L(
                        hasActiveHost
                            ? "Set a user and password or private key in Settings."
                            : "Add a Host Record to start browsing."
                    )
                )
                .fixedSize(horizontal: false, vertical: true)
                Button(L("Open Settings…")) { LeafiySettingsWindow.open() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .leafiyFileDrop(isTargeted: $listTargeted) { urls in
                model.panelDrop(urls, into: browser.path)
            }
            .leafiyDropHighlight(listTargeted)
        } else if !hasVisibleEntries && !browser.isLoading {
            EmptyStateView(
                systemImage: "folder",
                title: L("Empty folder"),
                subtitle: L("Drop files here to upload")
            )
            .leafiyFileDrop(isTargeted: $listTargeted) { urls in
                model.panelDrop(urls, into: browser.path)
            }
            .leafiyDropHighlight(listTargeted)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(browser.entries) { entry in
                        if model.settings.showHiddenFiles || !entry.name.hasPrefix(".") {
                            row(entry)
                        }
                    }
                }
                .padding(.vertical, LeafiyDesign.Spacing.xs)
            }
            .leafiyFileDrop(isTargeted: $listTargeted) { urls in
                model.panelDrop(urls, into: browser.path)
            }
            .leafiyDropHighlight(listTargeted)
        }
    }

    private func row(_ entry: RemoteEntry) -> some View {
        PanelRow(
            entry: entry,
            dropInto: { urls in
                model.panelDrop(urls, into: joinRemote(browser.path, entry.name))
            },
            open: {
                Task { await browser.enter(entry) }
            },
            promise: { model.dragOutPromise(for: entry) }
        )
        .contextMenu {
            Button(L("Rename…")) {
                renameTarget = entry
                renameName = entry.name
            }
            Button(L("Delete…"), role: .destructive) { deleteTarget = entry }
            Divider()
            Button(L("New Folder…")) {
                newFolderName = L("untitled folder")
                newFolderPrompt = true
            }
        }
    }

    // MARK: - Dialog plumbing

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    private var deletePresented: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }

    private var deleteQuestion: String {
        String(format: L("Delete “%@”?"), deleteTarget?.name ?? "")
    }
}

private struct PanelRow: View {
    let entry: RemoteEntry
    let dropInto: ([URL]) -> Void
    let open: () -> Void
    let promise: () -> LeafiyFilePromise?

    @State private var targeted = false
    @State private var hovering = false

    var body: some View {
        if entry.isDirectory {
            core
                .leafiyFileDrop(isTargeted: $targeted) { dropInto($0) }
                .leafiyDropHighlight(targeted)
                .onTapGesture(count: 2) { open() }
        } else if let promise = promise() {
            core.leafiyFilePromiseDragOut(promise)
        } else {
            core
        }
    }

    private var systemImage: String {
        if entry.isDirectory { return "folder.fill" }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "ico", "svg": return "photo"
        case "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "tar": return "shippingbox"
        case "mp4", "mov", "mkv", "avi", "webm": return "film"
        case "mp3", "wav", "flac", "aac", "ogg": return "music.note"
        default: return "doc.text"
        }
    }

    private var core: some View {
        HStack(spacing: LeafiyDesign.Spacing.s) {
            Image(systemName: systemImage)
                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 20)
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if !entry.isDirectory {
                Text(formatBytes(entry.size))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, LeafiyDesign.Spacing.m)
        .padding(.vertical, LeafiyDesign.Spacing.s)
        .contentShape(Rectangle())
        .background(Color.primary.opacity(hovering ? 0.055 : 0))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

/// The rsync install sheet keeps the selected command visible while probing,
/// running, or waiting for a sudo password.
struct RsyncInstallSheet: View {
    @ObservedObject var flow: RsyncInstallFlow
    let model: JoeyModel

    var body: some View {
        VStack(alignment: .leading, spacing: LeafiyDesign.Spacing.m) {
            Text(L("Install rsync"))
                .font(.headline)
            switch flow.phase {
            case .probing:
                HStack(spacing: LeafiyDesign.Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text(L("Checking the remote package manager…"))
                        .foregroundStyle(.secondary)
                }
            case .unavailable(let reason):
                Text(reason)
                    .foregroundStyle(.secondary)
                Text(L("Transfers keep working over sftp."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            case .ready, .needsPassword, .running, .failed:
                commandPreview
                if flow.phase == .needsPassword || isFailedAfterPassword {
                    SecureField(L("sudo password"), text: $flow.sudoPassword)
                        .textFieldStyle(.roundedBorder)
                }
                if case .failed(let message) = flow.phase {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(4)
                }
                if flow.phase == .running {
                    HStack(spacing: LeafiyDesign.Spacing.s) {
                        ProgressView().controlSize(.small)
                        Text(L("Running…")).foregroundStyle(.secondary)
                    }
                }
            case .succeeded:
                Label(L("rsync installed — fast transfers enabled."), systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
            HStack {
                Spacer()
                switch flow.phase {
                case .succeeded:
                    Button(L("Done")) { model.finishRsyncInstall(success: true) }
                        .keyboardShortcut(.defaultAction)
                case .unavailable:
                    Button(L("Close")) { model.finishRsyncInstall(success: false) }
                        .keyboardShortcut(.cancelAction)
                case .probing, .running:
                    Button(L("Cancel")) { model.finishRsyncInstall(success: false) }
                        .keyboardShortcut(.cancelAction)
                default:
                    Button(L("Cancel")) { model.finishRsyncInstall(success: false) }
                        .keyboardShortcut(.cancelAction)
                    Button(L("Install")) {
                        Task { await flow.run() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(flow.phase == .needsPassword && flow.sudoPassword.isEmpty)
                }
            }
        }
        .padding(LeafiyDesign.Spacing.xl)
        .frame(width: 320)
    }

    private var isFailedAfterPassword: Bool {
        if case .failed = flow.phase { return flow.plan?.sudoCommand != nil }
        return false
    }

    private var commandPreview: some View {
        Text(flow.displayCommand)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .padding(LeafiyDesign.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: LeafiyDesign.Radius.control))
    }
}

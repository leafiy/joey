import AppKit
import LeafiyUI
import LeafiyUICore
import SwiftUI

struct JoeySettingsView: View {
    @ObservedObject var model: JoeyModel

    var body: some View {
        LeafiyFamilySettings(language: model.language) {
            LeafiyGeneralPane(
                language: languageBinding,
                launchAtLogin: settingsBinding(\.launchAtLogin),
                applicationIconMode: settingsBinding(\.applicationIconMode)
            )
            HostsPane(model: model)
            privacyPane
        }
        .sheet(item: $model.rsyncInstall) { flow in
            RsyncInstallSheet(flow: flow, model: model)
        }
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { model.settings.selectedAppLanguage },
            set: { language in
                model.updateSettings { $0.selectedAppLanguage = language }
                LeafiyLocalization.language = language
            }
        )
    }

    private func settingsBinding<Value>(
        _ keyPath: WritableKeyPath<AppSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in model.updateSettings { $0[keyPath: keyPath] = value } }
        )
    }

    private var privacyPane: some View {
        SettingsPane(L("Privacy"), systemImage: "hand.raised", height: 340) {
            Section {
                Text(L("privacy.storage"))
                Text(L("privacy.transfer"))
                Text(L("privacy.hostkeys"))
            }
            .font(.callout)
        }
    }
}

// MARK: - Hosts

/// QSpace-style Host Record forms plus one-click `~/.ssh/config` import.
private struct HostsPane: View {
    @ObservedObject var model: JoeyModel
    @State private var importSummary: String?

    var body: some View {
        SettingsPane(L("Hosts"), systemImage: "server.rack", height: 520) {
            ForEach(model.settings.hosts) { host in
                HostSection(model: model, record: host)
            }
            Section {
                Button(L("Add Host")) {
                    model.updateSettings { settings in
                        var record = HostRecord()
                        record.name = L("New Host")
                        settings.hosts.append(record)
                        if settings.activeHostID == nil { settings.activeHostID = record.id }
                    }
                }
                Button(L("Import from ~/.ssh/config")) { runImport() }
                if let importSummary {
                    Text(importSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func runImport() {
        let imported = SSHConfigImport.importHosts()
        var added = 0
        model.updateSettings { settings in
            for entry in imported {
                let duplicate = settings.hosts.contains {
                    $0.name == entry.name
                        || ($0.host == entry.host && $0.port == entry.port
                            && $0.username == (entry.username ?? $0.username))
                }
                guard !duplicate else { continue }
                var record = HostRecord()
                record.name = entry.name
                record.host = entry.host
                record.port = entry.port
                record.username = entry.username ?? ""
                if let identityFile = entry.identityFile {
                    record.authMethod = .privateKey
                    record.privateKeyPath = identityFile
                }
                settings.hosts.append(record)
                added += 1
            }
        }
        importSummary =
            imported.isEmpty
            ? L("No hosts found in ~/.ssh/config.")
            : String(format: L("Imported %d new host(s)."), added)
    }
}

private struct HostSection: View {
    @ObservedObject var model: JoeyModel
    let record: HostRecord

    var body: some View {
        Section(record.displayName) {
            TextField(L("Name"), text: binding(\.name))
            TextField(L("Host"), text: binding(\.host))
                .autocorrectionDisabled()
            TextField(L("Port"), value: binding(\.port), format: .number.grouping(.never))
            TextField(L("User"), text: binding(\.username))
                .autocorrectionDisabled()
            TextField(L("Default directory"), text: binding(\.defaultDirectory))
                .autocorrectionDisabled()
            Toggle(L("Favorite"), isOn: binding(\.isFavorite))
                .disabled(favoriteLimitReached)
                .help(L("Favorite drops use this host’s default or last browsed directory."))
            Picker(L("Authentication"), selection: binding(\.authMethod)) {
                Text(L("Password")).tag(HostRecord.AuthMethod.password)
                Text(L("Private Key")).tag(HostRecord.AuthMethod.privateKey)
            }
            if record.authMethod == .password {
                SecureField(L("Password"), text: binding(\.password))
            } else {
                HStack {
                    TextField(L("Private key path"), text: binding(\.privateKeyPath))
                        .autocorrectionDisabled()
                    Menu {
                        ForEach(commonPrivateKeyPaths, id: \.self) { path in
                            Button(path) {
                                binding(\.privateKeyPath).wrappedValue = path
                            }
                        }
                        if !commonPrivateKeyPaths.isEmpty {
                            Divider()
                        }
                        Button(L("Choose Private Key…")) {
                            choosePrivateKey()
                        }
                    } label: {
                        Image(systemName: "folder")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(L("Choose Private Key…"))
                }
                SecureField(L("Key passphrase (optional)"), text: binding(\.keyPassphrase))
            }
            rsyncControls
            HStack {
                if model.settings.activeHostID == record.id {
                    Label(L("Active Host"), systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(L("Make Active")) { model.setActiveHost(record.id) }
                        .font(.caption)
                }
                Spacer()
                Button(L("Remove"), role: .destructive) {
                    model.updateSettings { settings in
                        settings.hosts.removeAll { $0.id == record.id }
                    }
                }
                .font(.caption)
            }
        }
        .task {
            await model.detectRsync(for: record.id)
        }
        .onChange(of: record) { oldRecord, newRecord in
            guard !oldRecord.connectionEquals(newRecord) else { return }
            Task { await model.detectRsync(for: newRecord.id) }
        }
    }

    private var rsyncControls: some View {
        VStack(alignment: .leading, spacing: LeafiyDesign.Spacing.xs) {
            HStack(spacing: LeafiyDesign.Spacing.s) {
                Text(L("rsync acceleration"))
                Spacer()
                rsyncStatusControl
            }
            rsyncStatusDetail
        }
    }

    @ViewBuilder
    private var rsyncStatusControl: some View {
        switch model.rsyncStatus(for: record.id) {
        case .checking:
            ProgressView()
                .controlSize(.small)
            Text(L("Checking…"))
                .foregroundStyle(.secondary)
        case .enabled:
            Label(L("Enabled"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .missing:
            Label(L("Not installed"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Button(L("Install Automatically…")) {
                model.beginRsyncInstall(for: record.id)
            }
            .buttonStyle(.borderless)
        case .unavailable:
            Text(L("Unavailable"))
                .foregroundStyle(.secondary)
        case .failed:
            Label(L("Detection failed"), systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
            Button(L("Retry")) {
                Task { await model.detectRsync(for: record.id, force: true) }
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var rsyncStatusDetail: some View {
        switch model.rsyncStatus(for: record.id) {
        case .enabled(let banner):
            Text(banner)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case .unavailable(let reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
        case .checking, .missing:
            EmptyView()
        }
    }

    private var isFavorite: Bool {
        model.settings.hosts.first(where: { $0.id == record.id })?.isFavorite
            ?? record.isFavorite
    }

    private var favoriteLimitReached: Bool {
        !isFavorite && model.settings.favoriteHosts.count >= HostRecord.maxFavoriteCount
    }

    private static let commonPrivateKeyNames = [
        "id_ed25519",
        "id_ecdsa",
        "id_ecdsa_sk",
        "id_ed25519_sk",
        "id_rsa",
    ]

    private var commonPrivateKeyPaths: [String] {
        Self.commonPrivateKeyNames.compactMap { name in
            let path = "~/.ssh/\(name)"
            let expandedPath = (path as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory)
                && !isDirectory.boolValue ? path : nil
        }
    }

    private func choosePrivateKey() {
        let panel = NSOpenPanel()
        panel.title = L("Choose Private Key")
        panel.message = L("Choose a private key file.")
        panel.prompt = L("Choose")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.directoryURL = privateKeyPickerDirectory

        guard panel.runModal() == .OK, let url = panel.url else { return }
        binding(\.privateKeyPath).wrappedValue = abbreviatedHomePath(url)
    }

    private var privateKeyPickerDirectory: URL {
        let fileManager = FileManager.default
        if !record.privateKeyPath.isEmpty {
            let selectedPath = (record.privateKeyPath as NSString).expandingTildeInPath
            let directory = URL(fileURLWithPath: selectedPath).deletingLastPathComponent()
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return directory
            }
        }

        let sshDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: sshDirectory.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return sshDirectory
        }
        return fileManager.homeDirectoryForCurrentUser
    }

    private func abbreviatedHomePath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private func binding<Value>(
        _ keyPath: WritableKeyPath<HostRecord, Value>
    ) -> Binding<Value> {
        let id = record.id
        let fallback = record[keyPath: keyPath]
        return Binding(
            get: {
                model.settings.hosts.first(where: { $0.id == id })
                    .map { $0[keyPath: keyPath] } ?? fallback
            },
            set: { value in
                model.updateSettings { settings in
                    if let index = settings.hosts.firstIndex(where: { $0.id == id }) {
                        settings.hosts[index][keyPath: keyPath] = value
                    }
                }
            }
        )
    }
}


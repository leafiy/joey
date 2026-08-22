import Foundation
import LeafiyUICore

/// Joey's settings document: family-standard fields plus Host Records.
/// Persisted as plaintext JSON — including passwords and key passphrases —
/// per leafiy-ui ADR-0002; the Privacy pane states this.
struct AppSettings: Codable, Equatable, LeafiyAppSettings {
    var appLanguage: String = AppLanguage.system.rawValue
    var launchAtLogin: Bool = false
    var applicationIconMode: LeafiyApplicationIconMode = .menuBar
    var showHiddenFiles = false
    var downloadDirectory = "~/Downloads"

    var hosts: [HostRecord] = []
    var activeHostID: UUID?

    static var defaults: AppSettings { AppSettings() }

    func normalized() -> AppSettings {
        var settings = self
        var favoriteCount = 0
        for index in settings.hosts.indices where settings.hosts[index].isFavorite {
            if favoriteCount < HostRecord.maxFavoriteCount {
                favoriteCount += 1
            } else {
                settings.hosts[index].isFavorite = false
            }
        }

        let hostIDs = Set(settings.hosts.map(\.id))
        if let active = settings.activeHostID, !hostIDs.contains(active) {
            settings.activeHostID = nil
        }
        if settings.activeHostID == nil {
            settings.activeHostID = settings.hosts.first?.id
        }
        return settings
    }

    // Tolerant decoding: any missing or legacy field falls back to defaults so
    // old settings files keep loading.
    enum CodingKeys: String, CodingKey {
        case appLanguage, launchAtLogin, applicationIconMode, showHiddenFiles
        case downloadDirectory
        case hosts, activeHostID, favorites
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings.defaults
        appLanguage =
            (try? container.decode(String.self, forKey: .appLanguage)) ?? defaults.appLanguage
        launchAtLogin =
            (try? container.decode(Bool.self, forKey: .launchAtLogin)) ?? defaults.launchAtLogin
        applicationIconMode =
            (try? container.decode(LeafiyApplicationIconMode.self, forKey: .applicationIconMode))
            ?? defaults.applicationIconMode
        showHiddenFiles =
            (try? container.decode(Bool.self, forKey: .showHiddenFiles))
            ?? defaults.showHiddenFiles
        downloadDirectory =
            (try? container.decode(String.self, forKey: .downloadDirectory))
            ?? defaults.downloadDirectory
        hosts = (try? container.decode([HostRecord].self, forKey: .hosts)) ?? defaults.hosts
        activeHostID = try? container.decode(UUID.self, forKey: .activeHostID)

        let legacyFavorites =
            (try? container.decode([LegacyFavorite].self, forKey: .favorites)) ?? []
        var favoriteCount = hosts.count(where: \.isFavorite)
        for favorite in legacyFavorites where favoriteCount < HostRecord.maxFavoriteCount {
            guard let index = hosts.firstIndex(where: { $0.id == favorite.hostID }),
                  !hosts[index].isFavorite else { continue }
            hosts[index].isFavorite = true
            if hosts[index].defaultDirectory.isEmpty {
                hosts[index].defaultDirectory = favorite.directory
            }
            favoriteCount += 1
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(appLanguage, forKey: .appLanguage)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(applicationIconMode, forKey: .applicationIconMode)
        try container.encode(showHiddenFiles, forKey: .showHiddenFiles)
        try container.encode(downloadDirectory, forKey: .downloadDirectory)
        try container.encode(hosts, forKey: .hosts)
        try container.encodeIfPresent(activeHostID, forKey: .activeHostID)
    }

    var selectedAppLanguage: AppLanguage {
        get { AppLanguage(rawValue: appLanguage) ?? .system }
        set { appLanguage = newValue.rawValue }
    }

    var downloadDirectoryURL: URL {
        let configured = downloadDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = configured.isEmpty ? AppSettings.defaults.downloadDirectory : configured
        return URL(
            fileURLWithPath: (path as NSString).expandingTildeInPath,
            isDirectory: true
        ).standardizedFileURL
    }

    var activeHost: HostRecord? {
        hosts.first(where: { $0.id == activeHostID }) ?? hosts.first
    }

    var favoriteHosts: [HostRecord] {
        Array(hosts.lazy.filter(\.isFavorite).prefix(HostRecord.maxFavoriteCount))
    }
}

private struct LegacyFavorite: Decodable {
    let hostID: UUID
    let directory: String
}

final class SettingsStore {
    private let store: LeafiySettingsStore<AppSettings>

    init(fileURL: URL? = nil) {
        self.store = fileURL.map { LeafiySettingsStore(fileURL: $0) }
            ?? .standard(directoryName: "Joey")
    }

    var hasSavedSettings: Bool {
        store.hasSavedSettings
    }

    func load() -> AppSettings {
        store.load()
    }

    func save(_ settings: AppSettings) throws {
        try store.save(settings)
    }
}

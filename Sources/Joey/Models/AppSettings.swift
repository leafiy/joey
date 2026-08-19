import Foundation
import LeafiyUICore

/// Joey's one settings document: family-standard fields plus Host Records and
/// Favorites. Persisted as plaintext JSON — including passwords and key
/// passphrases — per leafiy-ui ADR-0002; the Privacy pane states this.
struct AppSettings: Codable, Equatable, LeafiyAppSettings {
    var appLanguage: String = AppLanguage.system.rawValue
    var launchAtLogin: Bool = false
    var applicationIconMode: LeafiyApplicationIconMode = .menuBar

    var hosts: [HostRecord] = []
    var activeHostID: UUID?
    var favorites: [Favorite] = []

    static var defaults: AppSettings { AppSettings() }

    func normalized() -> AppSettings {
        var settings = self
        // Favorites: cap at the max, and drop entries whose host is gone.
        let hostIDs = Set(settings.hosts.map(\.id))
        settings.favorites = Array(
            settings.favorites.filter { hostIDs.contains($0.hostID) }.prefix(Favorite.maxCount))
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
        case appLanguage, launchAtLogin, applicationIconMode, hosts, activeHostID, favorites
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
        hosts = (try? container.decode([HostRecord].self, forKey: .hosts)) ?? defaults.hosts
        activeHostID = try? container.decode(UUID.self, forKey: .activeHostID)
        favorites =
            (try? container.decode([Favorite].self, forKey: .favorites)) ?? defaults.favorites
    }

    var selectedAppLanguage: AppLanguage {
        get { AppLanguage(rawValue: appLanguage) ?? .system }
        set { appLanguage = newValue.rawValue }
    }

    var activeHost: HostRecord? {
        hosts.first(where: { $0.id == activeHostID }) ?? hosts.first
    }
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

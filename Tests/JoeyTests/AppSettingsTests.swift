import XCTest
@testable import Joey

final class AppSettingsTests: XCTestCase {
    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("joey-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    func testRoundTripPersistsHostsAndFavorites() throws {
        let store = SettingsStore(fileURL: tempFileURL())
        var settings = AppSettings.defaults
        var host = HostRecord()
        host.name = "web-01"
        host.host = "example.com"
        host.username = "deploy"
        host.authMethod = .privateKey
        host.privateKeyPath = "~/.ssh/id_ed25519"
        settings.hosts = [host]
        settings.activeHostID = host.id
        settings.favorites = [Favorite(hostID: host.id, directory: "/var/www")]

        try store.save(settings)
        let loaded = store.load()
        XCTAssertEqual(loaded.hosts, settings.hosts)
        XCTAssertEqual(loaded.favorites, settings.favorites)
        XCTAssertEqual(loaded.activeHostID, host.id)
    }

    func testNormalizedCapsFavoritesAtThree() {
        var settings = AppSettings.defaults
        let host = HostRecord()
        settings.hosts = [host]
        settings.favorites = (0..<5).map { i in
            Favorite(hostID: host.id, directory: "/dir\(i)")
        }
        XCTAssertEqual(settings.normalized().favorites.count, Favorite.maxCount)
    }

    func testNormalizedDropsFavoritesForMissingHosts() {
        var settings = AppSettings.defaults
        let host = HostRecord()
        settings.hosts = [host]
        settings.favorites = [
            Favorite(hostID: host.id, directory: "/keep"),
            Favorite(hostID: UUID(), directory: "/dangling"),
        ]
        let normalized = settings.normalized()
        XCTAssertEqual(normalized.favorites.map(\.directory), ["/keep"])
    }

    func testNormalizedRepairsActiveHost() {
        var settings = AppSettings.defaults
        let host = HostRecord()
        settings.hosts = [host]
        settings.activeHostID = UUID()
        XCTAssertEqual(settings.normalized().activeHostID, host.id)
    }

    func testDecodeToleratesMissingFields() throws {
        let json = Data(#"{"appLanguage":"zh-Hans"}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(decoded.appLanguage, "zh-Hans")
        XCTAssertTrue(decoded.hosts.isEmpty)
        XCTAssertTrue(decoded.favorites.isEmpty)
    }
}

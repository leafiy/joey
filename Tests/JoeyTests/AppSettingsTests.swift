import XCTest
@testable import Joey

final class AppSettingsTests: XCTestCase {
    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("joey-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    func testRoundTripPersistsHostsAndPreferences() throws {
        let store = SettingsStore(fileURL: tempFileURL())
        var settings = AppSettings.defaults
        var host = HostRecord()
        host.name = "web-01"
        host.host = "example.com"
        host.username = "deploy"
        host.authMethod = .privateKey
        host.privateKeyPath = "~/.ssh/id_ed25519"
        host.defaultDirectory = "/srv/apps"
        host.isFavorite = true
        settings.showHiddenFiles = true
        settings.hosts = [host]
        settings.activeHostID = host.id

        try store.save(settings)
        let loaded = store.load()
        XCTAssertEqual(loaded.hosts, settings.hosts)
        XCTAssertTrue(loaded.showHiddenFiles)
        XCTAssertEqual(loaded.activeHostID, host.id)
    }

    func testLegacyHostWithoutDefaultDirectoryStillDecodes() throws {
        let json = Data(
            #"""
            {
              "hosts": [{
                "id": "00000000-0000-0000-0000-000000000001",
                "name": "legacy",
                "host": "example.com",
                "port": 22,
                "username": "deploy",
                "authMethod": "password",
                "password": "secret",
                "privateKeyPath": "",
                "keyPassphrase": "",
                "lastBrowsedDirectory": "/srv/current"
              }]
            }
            """#.utf8)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(decoded.hosts.count, 1)
        XCTAssertEqual(decoded.hosts[0].name, "legacy")
        XCTAssertEqual(decoded.hosts[0].defaultDirectory, "")
        XCTAssertEqual(decoded.hosts[0].lastBrowsedDirectory, "/srv/current")
    }

    func testDefaultDirectoryOverridesLastBrowsedDirectoryForActivation() {
        var host = HostRecord()
        XCTAssertNil(host.browserStartDirectory)

        host.lastBrowsedDirectory = "/srv/current"
        XCTAssertEqual(host.browserStartDirectory, "/srv/current")

        host.defaultDirectory = "/srv/default"
        XCTAssertEqual(host.browserStartDirectory, "/srv/default")
    }

    func testNormalizedCapsFavoriteHostsAtThree() {
        var settings = AppSettings.defaults
        settings.hosts = (0..<5).map { index in
            var host = HostRecord()
            host.name = "host-\(index)"
            host.isFavorite = true
            return host
        }

        let normalized = settings.normalized()
        XCTAssertEqual(normalized.favoriteHosts.count, HostRecord.maxFavoriteCount)
        XCTAssertEqual(normalized.favoriteHosts.map(\.name), ["host-0", "host-1", "host-2"])
    }

    func testLegacyFavoritesMigrateIntoMatchingHosts() throws {
        let json = Data(
            #"""
            {
              "hosts": [{
                "id": "00000000-0000-0000-0000-000000000001",
                "name": "legacy",
                "host": "example.com",
                "port": 22,
                "username": "deploy",
                "authMethod": "password",
                "password": "secret",
                "privateKeyPath": "",
                "keyPassphrase": "",
                "lastBrowsedDirectory": ""
              }],
              "favorites": [{
                "id": "00000000-0000-0000-0000-000000000002",
                "hostID": "00000000-0000-0000-0000-000000000001",
                "directory": "/srv/drop"
              }, {
                "id": "00000000-0000-0000-0000-000000000003",
                "hostID": "00000000-0000-0000-0000-000000000004",
                "directory": "/missing"
              }]
            }
            """#.utf8)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(decoded.favoriteHosts.map(\.name), ["legacy"])
        XCTAssertEqual(decoded.hosts[0].defaultDirectory, "/srv/drop")
        XCTAssertEqual(decoded.hosts[0].favoriteDirectory, "/srv/drop")
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
        XCTAssertFalse(decoded.showHiddenFiles)
        XCTAssertTrue(decoded.hosts.isEmpty)
        XCTAssertTrue(decoded.favoriteHosts.isEmpty)
    }
}

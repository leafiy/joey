import XCTest
@testable import Joey

final class SSHConfigImportTests: XCTestCase {
    private func write(_ text: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("joey-ssh-config-\(UUID().uuidString)")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func testParsesBasicFields() throws {
        let path = try write("""
        # comment
        Host web
            HostName example.com
            User deploy
            Port 2222
            IdentityFile ~/.ssh/id_ed25519

        Host nas backup-nas
            HostName 10.0.0.4
        """)
        let hosts = SSHConfigImport.importHosts(from: path)
        XCTAssertEqual(hosts.count, 2)
        XCTAssertEqual(hosts[0].name, "web")
        XCTAssertEqual(hosts[0].host, "example.com")
        XCTAssertEqual(hosts[0].username, "deploy")
        XCTAssertEqual(hosts[0].port, 2222)
        XCTAssertEqual(hosts[0].identityFile, NSString(string: "~/.ssh/id_ed25519").expandingTildeInPath)
        XCTAssertEqual(hosts[1].name, "nas")
        XCTAssertEqual(hosts[1].host, "10.0.0.4")
        XCTAssertEqual(hosts[1].port, 22)
        XCTAssertNil(hosts[1].identityFile)
    }

    func testSkipsWildcardAndMatchBlocks() throws {
        let path = try write("""
        Host *
            User everyone
        Match user deploy
            Port 2200
        Host real
            HostName real.example.com
        """)
        let hosts = SSHConfigImport.importHosts(from: path)
        XCTAssertEqual(hosts.map(\.name), ["real"])
        // The wildcard/Match values must not leak into the real block.
        XCTAssertNil(hosts[0].username)
        XCTAssertEqual(hosts[0].port, 22)
    }

    func testMissingFileYieldsEmpty() {
        XCTAssertTrue(SSHConfigImport.importHosts(from: "/nonexistent/ssh_config").isEmpty)
    }
}

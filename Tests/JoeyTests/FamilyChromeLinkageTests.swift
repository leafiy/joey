import LeafiyUI
import XCTest
@testable import Joey

final class FamilyChromeLinkageTests: XCTestCase {
    func testFamilyIdentityAlwaysHasDevelopmentFallbacks() {
        XCTAssertFalse(LeafiyAppIdentity.current.name.isEmpty)
        XCTAssertFalse(LeafiyAppIdentity.current.bundleIdentifier.isEmpty)
    }

    func testHostRecordConnectionIdentityIgnoresBrowseState() {
        var a = HostRecord()
        a.host = "example.com"
        a.username = "deploy"
        var b = a
        b.name = "renamed"
        b.lastBrowsedDirectory = "/srv"
        XCTAssertTrue(a.connectionEquals(b))
        b.port = 2222
        XCTAssertFalse(a.connectionEquals(b))
    }
}

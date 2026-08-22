import XCTest
@testable import Joey

@MainActor
final class RemotePathTests: XCTestCase {
    func testPosixBreadcrumbsKeepEachAncestorNavigable() {
        let breadcrumbs = BrowserModel.breadcrumbs(for: "/var/www/html")

        XCTAssertEqual(breadcrumbs.map { $0.name }, ["/", "var", "www", "html"])
        XCTAssertEqual(breadcrumbs.map { $0.path }, ["/", "/var", "/var/www", "/var/www/html"])
    }

    func testWindowsBreadcrumbsSplitAndPreserveBackslashes() {
        let breadcrumbs = BrowserModel.breadcrumbs(for: #"C:\Users\leafiy\Documents"#)

        XCTAssertEqual(breadcrumbs.map { $0.name }, ["C:", "Users", "leafiy", "Documents"])
        XCTAssertEqual(
            breadcrumbs.map { $0.path },
            [#"C:\"#, #"C:\Users"#, #"C:\Users\leafiy"#, #"C:\Users\leafiy\Documents"#]
        )
    }

    func testJoinRemotePreservesWindowsSeparator() {
        XCTAssertEqual(joinRemote(#"C:\Users\leafiy"#, "Documents"), #"C:\Users\leafiy\Documents"#)
    }
}

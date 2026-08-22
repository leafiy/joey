import LeafiyUICore
import XCTest
@testable import Joey

final class UserFacingErrorTests: XCTestCase {
    func testWindowsDirectoryAccessFailureExplainsPermissionWithoutProtocolDetail() {
        let originalLanguage = LeafiyLocalization.language
        defer { LeafiyLocalization.language = originalLanguage }
        LeafiyLocalization.language = .english

        let error = SSHEngineError.sftp(
            "opendir C:\\Users\\Jo (sftp code 5): SFTP server: Bad message")
        let message = UserFacingError.message(for: error, during: .browse)

        XCTAssertEqual(message, "You don’t have permission to open this folder.")
        XCTAssertFalse(message.localizedCaseInsensitiveContains("sftp"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("code"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("bad message"))
    }

    func testDeletePermissionMessageDoesNotExposeTheProtocolDiagnostic() {
        let originalLanguage = LeafiyLocalization.language
        defer { LeafiyLocalization.language = originalLanguage }
        LeafiyLocalization.language = .english

        let error = SSHEngineError.sftp("unlink /srv/report.pdf (sftp code 3): Permission denied")
        let message = UserFacingError.message(for: error, during: .delete)

        XCTAssertEqual(message, "You don’t have permission to delete this item.")
        XCTAssertFalse(message.localizedCaseInsensitiveContains("sftp"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("permission denied"))
    }

    func testConnectionTimeoutDoesNotExposeEngineDiagnostic() {
        let originalLanguage = LeafiyLocalization.language
        defer { LeafiyLocalization.language = originalLanguage }
        LeafiyLocalization.language = .english

        let message = UserFacingError.message(
            for: SSHEngineError.session("connect to example.com:22 failed: Connection timed out"),
            during: .browse)

        XCTAssertEqual(
            message,
            "The connection timed out. Check the host address and network, then try again.")
        XCTAssertFalse(message.localizedCaseInsensitiveContains("example.com"))
    }
}

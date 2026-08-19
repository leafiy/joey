import XCTest
@testable import Joey

final class RsyncSupportTests: XCTestCase {
    func testDetectionParsing() {
        XCTAssertEqual(
            RsyncSupport.parseDetection(ExecResult(
                exitStatus: 0,
                stdout: "rsync  version 3.2.7  protocol version 31\n",
                stderr: "")),
            .present(banner: "rsync  version 3.2.7  protocol version 31"))
        XCTAssertEqual(
            RsyncSupport.parseDetection(ExecResult(exitStatus: 127, stdout: "", stderr: "")),
            .missing)
        XCTAssertEqual(
            RsyncSupport.parseDetection(ExecResult(exitStatus: 1, stdout: "", stderr: "")),
            .missing)
        if case .unknown = RsyncSupport.parseDetection(
            ExecResult(exitStatus: 5, stdout: "", stderr: "boom")) {
        } else {
            XCTFail("non-standard exit should be unknown")
        }
    }

    func testInstallPlanSudoLadder() {
        // Root: no sudo wrapper.
        let root = RsyncSupport.installPlan(managerName: "apt-get", isRoot: true, hasNopasswdSudo: false)
        XCTAssertNil(root?.sudoCommand)
        // NOPASSWD: display shows sudo, no fed password.
        let nopass = RsyncSupport.installPlan(managerName: "dnf", isRoot: false, hasNopasswdSudo: true)
        XCTAssertNil(nopass?.sudoCommand)
        XCTAssertTrue(nopass?.display.hasPrefix("sudo ") == true)
        // Password sudo: -S on stdin, empty prompt, no PTY.
        let password = RsyncSupport.installPlan(managerName: "pacman", isRoot: false, hasNopasswdSudo: false)
        XCTAssertTrue(password?.sudoCommand?.contains("sudo -S -p ''") == true)
        // brew never uses sudo.
        let brew = RsyncSupport.installPlan(managerName: "brew", isRoot: false, hasNopasswdSudo: false)
        XCTAssertNil(brew?.sudoCommand)
        XCTAssertEqual(brew?.display, "brew install rsync")
        // Unknown manager.
        XCTAssertNil(RsyncSupport.installPlan(managerName: "nix", isRoot: false, hasNopasswdSudo: false))
    }

    func testUploadArgumentsQuoteRemotePath() {
        var record = HostRecord()
        record.host = "example.com"
        record.port = 2222
        record.username = "deploy"
        record.authMethod = .privateKey
        record.privateKeyPath = "/k"
        let args = RsyncSupport.uploadArguments(
            localPath: "/tmp/f", record: record, keyPath: "/k",
            remoteDirectory: "/var/it's here", modern: true)
        XCTAssertTrue(args.contains("--info=progress2"))
        XCTAssertEqual(args.last, "deploy@example.com:'/var/it'\\''s here/'")
        XCTAssertTrue(args.contains(where: { $0.hasPrefix("ssh -p 2222 -i /k") }))
    }

    func testProgressPercentParsing() {
        XCTAssertEqual(
            RsyncSupport.parseProgressPercent(
                "1,036,923,510  99%   39.90MB/s    0:00:24 (xfr#1, to-chk=0/2)"),
            0.99)
        XCTAssertNil(RsyncSupport.parseProgressPercent("building file list ..."))
    }
}

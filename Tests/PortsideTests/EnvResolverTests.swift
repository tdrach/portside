import XCTest
@testable import Portside

final class EnvResolverTests: XCTestCase {

    private func block(junk: String = "", entries: [String]) -> Data {
        var data = Data(junk.utf8)
        data.append(Data(EnvResolver.sentinel.utf8))
        for entry in entries {
            data.append(Data(entry.utf8))
            data.append(0)
        }
        return data
    }

    func testParsesEntriesAfterSentinel() {
        let env = EnvResolver.parse(block(entries: ["PATH=/usr/bin:/bin", "HOME=/Users/x"]))
        XCTAssertEqual(env?["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(env?["HOME"], "/Users/x")
    }

    func testRcFileNoiseBeforeSentinelIsIgnored() {
        let env = EnvResolver.parse(block(
            junk: "Welcome!\n\u{1B}[2JPATH=/fake\n", entries: ["PATH=/real"]
        ))
        XCTAssertEqual(env?["PATH"], "/real")
    }

    func testMissingSentinelFails() {
        XCTAssertNil(EnvResolver.parse(Data("PATH=/usr/bin\0".utf8)))
    }

    func testMissingPathFails() {
        XCTAssertNil(EnvResolver.parse(block(entries: ["HOME=/Users/x"])))
    }

    func testInvalidNamesAreSkipped() {
        // Exported bash functions and other oddities must not survive.
        let env = EnvResolver.parse(block(entries: [
            "PATH=/usr/bin",
            "BASH_FUNC_ls%%=() { evil; }",
            "1BAD=x",
            "=noname",
        ]))
        XCTAssertEqual(env?.count, 1)
    }

    func testValuesContainingEqualsSurvive() {
        let env = EnvResolver.parse(block(entries: [
            "PATH=/usr/bin", "OPTS=--flag=1 --other=2",
        ]))
        XCTAssertEqual(env?["OPTS"], "--flag=1 --other=2")
    }

    func testInvocationFlags() {
        XCTAssertEqual(EnvResolver.invocationFlags(forShell: "/bin/zsh"), ["-l", "-i", "-c"])
        XCTAssertEqual(EnvResolver.invocationFlags(forShell: "/opt/homebrew/bin/fish"), ["-l", "-i", "-c"])
        XCTAssertEqual(EnvResolver.invocationFlags(forShell: "/bin/tcsh"), ["-c"])
        XCTAssertNil(EnvResolver.invocationFlags(forShell: "/usr/local/bin/xonsh"),
                     "unknown shells must be skipped, not guessed at")
    }

    func testLoginShellIsExecutable() {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: EnvResolver.loginShell()))
    }

    /// Live capture against the real login shell. For mainstream shells this
    /// must succeed outright; only exotic shells may return nil.
    func testLiveCapture() {
        let shellName = URL(fileURLWithPath: EnvResolver.loginShell()).lastPathComponent
        let env = EnvResolver.capture(timeout: 15)
        if ["zsh", "bash", "sh"].contains(shellName) {
            XCTAssertNotNil(env, "capture must work for \(shellName)")
        }
        if let env {
            XCTAssertNotNil(env["PATH"])
            XCTAssertFalse(env["PATH"]!.isEmpty)
        }
    }
}

final class ExitStatusTests: XCTestCase {

    func testNormalExitCodes() {
        XCTAssertEqual(AppModel.decodeExitStatus(0), 0)
        XCTAssertEqual(AppModel.decodeExitStatus(7 << 8), 7)
        XCTAssertEqual(AppModel.decodeExitStatus(255 << 8), 255)
    }

    func testSignalDeaths() {
        XCTAssertEqual(AppModel.decodeExitStatus(9), 137)   // SIGKILL
        XCTAssertEqual(AppModel.decodeExitStatus(15), 143)  // SIGTERM
    }
}

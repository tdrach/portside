import XCTest
@testable import Portside

final class ShellQuotingTests: XCTestCase {

    func testSafeArgumentsPassUnquoted() {
        XCTAssertEqual(ShellQuoting.quote("npm"), "npm")
        XCTAssertEqual(ShellQuoting.quote("/usr/local/bin/node"), "/usr/local/bin/node")
        XCTAssertEqual(ShellQuoting.quote("--port=3000"), "--port=3000")
    }

    func testSpacesAreQuoted() {
        XCTAssertEqual(ShellQuoting.quote("My Projects"), "'My Projects'")
    }

    func testSingleQuotesAreEscaped() {
        XCTAssertEqual(ShellQuoting.quote("it's"), "'it'\\''s'")
    }

    func testShellMetacharactersAreNeutralized() {
        XCTAssertEqual(ShellQuoting.quote("$(reboot)"), "'$(reboot)'")
        XCTAssertEqual(ShellQuoting.quote("a;b|c&d"), "'a;b|c&d'")
        XCTAssertEqual(ShellQuoting.quote("`ls`"), "'`ls`'")
    }

    func testEmptyArgumentBecomesEmptyQuotes() {
        XCTAssertEqual(ShellQuoting.quote(""), "''")
    }

    func testJoin() {
        XCTAssertEqual(
            ShellQuoting.join(["node", "/Users/me/My App/server.js"]),
            "node '/Users/me/My App/server.js'"
        )
    }

    /// Property test: quoting must survive a real shell round-trip unchanged.
    func testRoundTripThroughRealShell() throws {
        let nasty = [
            "plain",
            "has space",
            "it's quoted",
            "$(touch /tmp/pwned)",
            "`whoami`",
            "semi;colon && stuff | pipe",
            "unicode – path ✓",
        ]
        let command = "printf '%s\\n' " + ShellQuoting.join(nasty)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .dropLast() // trailing newline
        XCTAssertEqual(Array(lines), nasty)
    }
}

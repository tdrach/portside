import Darwin
import XCTest
@testable import Portside

final class CommandGuessTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("portside-guess-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ name: String, _ contents: String, executable: Bool = false) throws {
        let url = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path
            )
        }
    }

    func testDevScriptWithNoLockfileUsesNpm() throws {
        try write("package.json", #"{"scripts": {"dev": "vite"}}"#)
        XCTAssertEqual(CommandGuess.guess(directory: tempDir.path), "npm run dev")
    }

    func testStartScriptUsesNpmStart() throws {
        try write("package.json", #"{"scripts": {"start": "node server.js"}}"#)
        XCTAssertEqual(CommandGuess.guess(directory: tempDir.path), "npm start")
    }

    func testLockfilesPickTheRunner() throws {
        try write("package.json", #"{"scripts": {"dev": "next dev"}}"#)
        try write("pnpm-lock.yaml", "")
        XCTAssertEqual(CommandGuess.guess(directory: tempDir.path), "pnpm run dev")
    }

    func testMonorepoWorkspaceFindsRootLockfile() throws {
        // Lockfile at the root, package.json in the workspace package.
        try write("pnpm-lock.yaml", "")
        try write("packages/web/package.json", #"{"scripts": {"dev": "vite"}}"#)
        let workspace = tempDir.appendingPathComponent("packages/web").path
        XCTAssertEqual(CommandGuess.guess(directory: workspace), "pnpm run dev")
    }

    func testGitRootStopsTheLockfileWalk() throws {
        try write("pnpm-lock.yaml", "") // above the repo boundary — ignored
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("repo/.git"), withIntermediateDirectories: true
        )
        try write("repo/package.json", #"{"scripts": {"dev": "vite"}}"#)
        let repo = tempDir.appendingPathComponent("repo").path
        XCTAssertEqual(CommandGuess.guess(directory: repo), "npm run dev")
    }

    func testMalformedPackageJSONFallsThrough() throws {
        try write("package.json", "{not json")
        XCTAssertNil(CommandGuess.guess(directory: tempDir.path))
    }

    func testNoRelevantScriptsReturnsNil() throws {
        try write("package.json", #"{"scripts": {"test": "jest"}}"#)
        XCTAssertNil(CommandGuess.guess(directory: tempDir.path))
    }

    func testRailsConvention() throws {
        try write("Gemfile", "gem 'rails'")
        try write("bin/rails", "#!/usr/bin/env ruby", executable: true)
        XCTAssertEqual(CommandGuess.guess(directory: tempDir.path), "bin/rails server")
    }

    func testDjangoConvention() throws {
        try write("manage.py", "#django")
        XCTAssertEqual(
            CommandGuess.guess(directory: tempDir.path), "python3 manage.py runserver"
        )
    }

    func testBinDevBeatsOtherConventions() throws {
        try write("Gemfile", "")
        try write("bin/rails", "#!", executable: true)
        try write("bin/dev", "#!", executable: true)
        XCTAssertEqual(CommandGuess.guess(directory: tempDir.path), "bin/dev")
    }

    // MARK: - safeReadRegularFile hardening

    func testFIFOPackageJSONDoesNotHang() throws {
        let fifoPath = tempDir.appendingPathComponent("package.json").path
        XCTAssertEqual(mkfifo(fifoPath, 0o644), 0)
        let started = Date()
        XCTAssertNil(CommandGuess.guess(directory: tempDir.path))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0,
                          "FIFO read must not block")
    }

    func testSymlinkedPackageJSONIsRefused() throws {
        let target = tempDir.appendingPathComponent("real.json")
        try #"{"scripts": {"dev": "x"}}"#.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: tempDir.appendingPathComponent("package.json"),
            withDestinationURL: target
        )
        XCTAssertNil(CommandGuess.safeReadRegularFile(
            tempDir.appendingPathComponent("package.json").path
        ))
    }

    func testOversizedFileIsRefused() throws {
        let big = Data(repeating: 0x20, count: 2_000_000)
        try big.write(to: tempDir.appendingPathComponent("package.json"))
        XCTAssertNil(CommandGuess.guess(directory: tempDir.path))
    }

    func testGuessNeverWritesIntoTheDirectory() throws {
        try write("package.json", #"{"scripts": {"dev": "vite"}}"#)
        let before = try FileManager.default.contentsOfDirectory(atPath: tempDir.path).sorted()
        _ = CommandGuess.guess(directory: tempDir.path)
        let after = try FileManager.default.contentsOfDirectory(atPath: tempDir.path).sorted()
        XCTAssertEqual(before, after)
    }
}

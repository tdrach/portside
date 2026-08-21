import XCTest
@testable import Portside

final class MatchingTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("portside-match-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func detected(
        pid: Int32 = 100, port: Int = 3000, pgid: Int32 = 100,
        cwd: String? = nil
    ) -> DetectedServer {
        DetectedServer(
            pid: pid, port: port, pgid: pgid, processName: "node",
            commandLine: nil, cwd: cwd, adoption: nil
        )
    }

    private func saved(
        name: String = "app", directory: String, command: String = "npm run dev",
        port: Int? = nil
    ) -> Server {
        Server(name: name, directory: directory, command: command, port: port)
    }

    // MARK: - canonicalPath

    func testCanonicalResolvesSymlinks() throws {
        let real = tempDir.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = tempDir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(
            Matching.canonicalPath(link.path),
            Matching.canonicalPath(real.path)
        )
    }

    func testCanonicalResolvesTmpToPrivate() {
        XCTAssertEqual(Matching.canonicalPath("/tmp"), "/private/tmp")
    }

    func testCanonicalIsCaseInsensitive() throws {
        let real = tempDir.appendingPathComponent("MyProject")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let flipped = tempDir.appendingPathComponent("myproject")
        XCTAssertEqual(
            Matching.canonicalPath(flipped.path),
            Matching.canonicalPath(real.path)
        )
    }

    func testCanonicalExpandsTilde() {
        XCTAssertEqual(
            Matching.canonicalPath("~"),
            Matching.canonicalPath(NSHomeDirectory())
        )
    }

    // MARK: - claimant

    func testManagedPgidBeatsEverything() {
        let mine = saved(directory: "/a", port: 9999)
        let other = saved(name: "other", directory: "/b", port: 3000)
        let listener = detected(pgid: 42, cwd: "/b")
        // Port says `other`, but pgid 42 is a run owned by `mine`.
        let owner = Matching.claimant(
            of: listener, saved: [other, mine],
            managedPgids: [42: mine.id], canonical: { $0 }
        )
        XCTAssertEqual(owner, mine.id)
    }

    func testPortMatchWithMatchingCwdClaims() {
        let entry = saved(directory: "/repo", port: 3000)
        let owner = Matching.claimant(
            of: detected(cwd: "/repo"), saved: [entry],
            managedPgids: [:], canonical: { $0 }
        )
        XCTAssertEqual(owner, entry.id)
    }

    func testPortSquatterWithDifferentCwdIsRefused() {
        // Another project on this row's port must NOT be claimed — clicking
        // Stop on the row would kill an unrelated dev server.
        let entry = saved(directory: "/repo-a", port: 3000)
        let owner = Matching.claimant(
            of: detected(cwd: "/repo-b"), saved: [entry],
            managedPgids: [:], canonical: { $0 }
        )
        XCTAssertNil(owner)
    }

    func testPortMatchWithUnknowableCwdIsRefused() {
        // A bare port match authorizes Stop to signal the process — without
        // cwd corroboration that's how you kill ControlCenter (every
        // launchd-spawned app has cwd "/", and AirPlay holds 5000/7000).
        let entry = saved(directory: "/repo", port: 3000)
        XCTAssertNil(Matching.claimant(
            of: detected(cwd: nil), saved: [entry],
            managedPgids: [:], canonical: { $0 }
        ))
        XCTAssertNil(Matching.claimant(
            of: detected(port: 5000, cwd: "/"), saved: [saved(directory: "/flask", port: 5000)],
            managedPgids: [:], canonical: { $0 }
        ))
    }

    func testManagedRunWithUnknowableCwdIsStillClaimed() {
        // pgid evidence is stronger than cwd — our own child stays claimed.
        let entry = saved(directory: "/repo", port: 3000)
        let owner = Matching.claimant(
            of: detected(pgid: 77, cwd: nil), saved: [entry],
            managedPgids: [77: entry.id], canonical: { $0 }
        )
        XCTAssertEqual(owner, entry.id)
    }

    func testClaimantThroughRealCanonicalPaths() throws {
        // Symlinked saved directory vs. real cwd, mixed case — must match
        // through the actual canonicalPath, not just an identity closure.
        let real = tempDir.appendingPathComponent("RealApp")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = tempDir.appendingPathComponent("link-to-app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let entry = saved(directory: link.path, port: 3000)
        let owner = Matching.claimant(
            of: detected(cwd: tempDir.appendingPathComponent("realapp").path),
            saved: [entry], managedPgids: [:],
            canonical: Matching.canonicalPath
        )
        XCTAssertEqual(owner, entry.id)
    }

    func testPortlessEntryClaimsByDirectory() {
        let entry = saved(directory: "/repo", port: nil)
        let owner = Matching.claimant(
            of: detected(cwd: "/repo"), saved: [entry],
            managedPgids: [:], canonical: { $0 }
        )
        XCTAssertEqual(owner, entry.id)
    }

    func testDirectoryOwnerBeatsPortSquatteeRow() {
        // Listener's cwd belongs to B (portless) but its port belongs to A:
        // B is the real owner.
        let a = saved(name: "a", directory: "/repo-a", port: 3000)
        let b = saved(name: "b", directory: "/repo-b", port: nil)
        let owner = Matching.claimant(
            of: detected(cwd: "/repo-b", ), saved: [a, b],
            managedPgids: [:], canonical: { $0 }
        )
        XCTAssertEqual(owner, b.id)
    }

    func testUnclaimedReturnsNil() {
        let entry = saved(directory: "/repo", port: 8080)
        XCTAssertNil(Matching.claimant(
            of: detected(cwd: "/elsewhere"), saved: [entry],
            managedPgids: [:], canonical: { $0 }
        ))
    }

    // MARK: - isAdoptableDirectory

    func testUserCodeDirectoriesAreAdoptable() {
        XCTAssertTrue(Matching.isAdoptableDirectory(NSHomeDirectory() + "/Code/my-app"))
        XCTAssertTrue(Matching.isAdoptableDirectory("/private/tmp/scratch-app"))
        XCTAssertTrue(Matching.isAdoptableDirectory("/Volumes/External/work/app"))
    }

    func testSystemAndAppInternalsAreNot() {
        XCTAssertFalse(Matching.isAdoptableDirectory("/"))
        XCTAssertFalse(Matching.isAdoptableDirectory("/Applications/Xcode.app/Contents"))
        XCTAssertFalse(Matching.isAdoptableDirectory("/System/Library"))
        XCTAssertFalse(Matching.isAdoptableDirectory("/usr/local/whatever"))
        XCTAssertFalse(Matching.isAdoptableDirectory("/opt/homebrew/var/www"))
        XCTAssertFalse(Matching.isAdoptableDirectory(NSHomeDirectory() + "/Library/Caches/x"))
    }

    func testDaemonAndToolStateDirectoriesAreNot() {
        XCTAssertFalse(Matching.isAdoptableDirectory(NSHomeDirectory()))
        XCTAssertFalse(Matching.isAdoptableDirectory(NSHomeDirectory() + "/.colima/docker"))
        XCTAssertFalse(Matching.isAdoptableDirectory(NSHomeDirectory() + "/Code/app/node_modules/.bin"))
        XCTAssertFalse(Matching.isAdoptableDirectory("/private/var/folders/ab/xyz/T/work"))
        XCTAssertFalse(Matching.isAdoptableDirectory(NSHomeDirectory() + "/Code/app/dist/Foo.app/Contents"))
    }
}

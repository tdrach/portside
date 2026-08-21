import Darwin
import XCTest
@testable import Portside

final class StoreTests: XCTestCase {

    private var base: URL!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("portside-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private var portsideDir: URL { base.appendingPathComponent("Portside") }

    func testRoundTrip() {
        let store = ServerStore(baseDirectory: base)
        let servers = [
            Server(name: "app", directory: "~/Code/app", command: "npm run dev", port: 3000),
            Server(name: "api", directory: "~/Code/api", command: "make run", port: nil,
                   urlOverride: "https://localhost:8443"),
        ]
        store.save(servers)
        XCTAssertEqual(ServerStore(baseDirectory: base).load(), servers)
    }

    func testLegacyProjectsFileMigrates() throws {
        let store = ServerStore(baseDirectory: base)
        let servers = [Server(name: "old", directory: "~/x", command: "npm start", port: 4000)]
        let data = try JSONEncoder().encode(servers)
        try data.write(to: portsideDir.appendingPathComponent("projects.json"))
        XCTAssertEqual(store.load(), servers)
        // Migration persisted to the new filename.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: portsideDir.appendingPathComponent("servers.json").path
        ))
    }

    func testCorruptFileIsPreservedNotOverwritten() throws {
        let store = ServerStore(baseDirectory: base)
        let file = portsideDir.appendingPathComponent("servers.json")
        try "{definitely not json".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.load(), [])
        // The user's (possibly hand-edited) data is set aside, not destroyed.
        let backup = portsideDir.appendingPathComponent("servers.json.corrupt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(
            try String(contentsOf: backup, encoding: .utf8), "{definitely not json"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testMissingFileLoadsEmpty() {
        XCTAssertEqual(ServerStore(baseDirectory: base).load(), [])
    }

    func testSavedFileHasPrivatePermissions() throws {
        let store = ServerStore(baseDirectory: base)
        store.save([Server(name: "a", directory: "/x", command: "c", port: 1)])
        let attrs = try FileManager.default.attributesOfItem(
            atPath: portsideDir.appendingPathComponent("servers.json").path
        )
        XCTAssertEqual(((attrs[.posixPermissions] as? Int) ?? 0) & 0o777, 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: portsideDir.path)
        XCTAssertEqual(((dirAttrs[.posixPermissions] as? Int) ?? 0) & 0o777, 0o700)
    }

    func testLogURLsDoNotCollide() {
        let store = ServerStore(baseDirectory: base)
        let a = Server(name: "web", directory: "/a", command: "x", port: 3000)
        let b = Server(name: "web", directory: "/b", command: "y", port: 3001)
        let c = Server(name: "web", directory: "/c", command: "z", port: nil)
        let d = Server(name: "web", directory: "/d", command: "w", port: nil)
        let urls = [a, b, c, d].map { store.logURL(for: $0).lastPathComponent }
        XCTAssertEqual(Set(urls).count, 4, "log files must be distinct: \(urls)")
    }

    func testSlug() {
        let store = ServerStore(baseDirectory: base)
        XCTAssertEqual(store.slug("Ops & Stuff!"), "ops-stuff")
        XCTAssertEqual(store.slug(""), "server")
        XCTAssertEqual(store.slug("---"), "server")
    }

    func testTombstonesRoundTripAndCap() {
        let store = ServerStore(baseDirectory: base)
        let stones = (0..<250).map {
            ServerStore.Tombstone(directory: "/d\($0)", command: "c\($0)")
        }
        store.saveTombstones(stones)
        let loaded = store.loadTombstones()
        XCTAssertEqual(loaded.count, 200, "tombstones are capped")
        XCTAssertEqual(loaded.last, stones.last, "newest entries survive the cap")
    }

    func testSymlinkedStoreDirectoryIsQuarantined() throws {
        // Plant a symlink where our directory should be — writes must not
        // follow it into the target.
        let victim = base.appendingPathComponent("victim-repo")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: portsideDir, withDestinationURL: victim
        )

        let store = ServerStore(baseDirectory: base)
        store.save([Server(name: "a", directory: "/x", command: "c", port: 1)])

        // Nothing was written into the symlink target…
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: victim.path), []
        )
        // …and the real directory exists with our file.
        var linkStat = stat()
        XCTAssertEqual(lstat(portsideDir.path, &linkStat), 0)
        XCTAssertEqual(linkStat.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(store.load().count, 1)
    }

    func testRepeatedSymlinkAttackWithStaleQuarantine() throws {
        // A leftover .quarantined from a previous attack must not let a fresh
        // symlink survive (moveItem would fail, createDirectory would then
        // succeed silently *through* the link).
        let victim = base.appendingPathComponent("victim-repo")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try "old".write(
            to: base.appendingPathComponent("Portside.quarantined"),
            atomically: true, encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: portsideDir, withDestinationURL: victim
        )

        let store = ServerStore(baseDirectory: base)
        store.save([Server(name: "a", directory: "/x", command: "c", port: 1)])

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: victim.path), [],
            "nothing may be written through the planted symlink"
        )
        var linkStat = stat()
        XCTAssertEqual(lstat(portsideDir.path, &linkStat), 0)
        XCTAssertEqual(linkStat.st_mode & S_IFMT, S_IFDIR)
    }
}

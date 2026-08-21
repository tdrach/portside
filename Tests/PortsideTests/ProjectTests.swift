import Darwin
import XCTest
@testable import Portside

final class ProjectAggregateTests: XCTestCase {

    func testEmpty() {
        XCTAssertEqual(ProjectAggregate.compute([]), .empty)
    }

    func testAllStopped() {
        XCTAssertEqual(
            ProjectAggregate.compute([.stopped, .stopped]), .allStopped
        )
    }

    func testAllRunning() {
        XCTAssertEqual(
            ProjectAggregate.compute([.running(external: false), .running(external: true)]),
            .allRunning(total: 2)
        )
    }

    func testPartialMix() {
        XCTAssertEqual(
            ProjectAggregate.compute([.running(external: false), .stopped, .stopped]),
            .partial(up: 1, total: 3)
        )
    }

    func testStartingIsUpButNotSteadyState() {
        XCTAssertEqual(
            ProjectAggregate.compute([.starting, .stopped]),
            .partial(up: 1, total: 2)
        )
        // A member still binding its port keeps the whole project in
        // partial — the chip must not go solid green early.
        XCTAssertEqual(
            ProjectAggregate.compute([.starting, .running(external: false)]),
            .partial(up: 2, total: 2)
        )
    }
}

final class ProjectStoreTests: XCTestCase {

    private var base: URL!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("portside-proj-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testProjectsRoundTrip() {
        let store = ServerStore(baseDirectory: base)
        let projects = [
            Project(name: "stack", collapsed: true, orderedStart: true),
            Project(name: "other"),
        ]
        store.saveProjects(projects)
        XCTAssertEqual(ServerStore(baseDirectory: base).loadProjects(), projects)
    }

    /// The regression that matters: the legacy servers migration reads
    /// "projects.json" — the Project store must never collide with it.
    func testLegacyServerMigrationUnaffectedByProjectStore() throws {
        let store = ServerStore(baseDirectory: base)
        store.saveProjects([Project(name: "stack")])

        let legacyServers = [Server(name: "old", directory: "~/x", command: "npm start", port: 4000)]
        let data = try JSONEncoder().encode(legacyServers)
        try data.write(to: base.appendingPathComponent("Portside/projects.json"))

        XCTAssertEqual(store.load(), legacyServers, "legacy migration must still work")
        XCTAssertEqual(store.loadProjects().count, 1, "project store must survive alongside")
    }

    func testServersWithoutProjectIDDecode() throws {
        // Pre-Projects servers.json files must load unchanged.
        let json = #"[{"id":"11111111-1111-1111-1111-111111111111","name":"a","directory":"/x","command":"c"}]"#
        let servers = try JSONDecoder().decode([Server].self, from: Data(json.utf8))
        XCTAssertNil(servers[0].projectID)
    }

    func testCorruptProjectsFileIsPreserved() throws {
        let store = ServerStore(baseDirectory: base)
        let url = base.appendingPathComponent("Portside/server-projects.json")
        try "{nope".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.loadProjects(), [])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: base.appendingPathComponent("Portside/server-projects.json.corrupt").path
        ))
    }
}

final class PortReadinessTests: XCTestCase {

    private func listen(on port: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 4) == 0 else { close(fd); return nil }
        return fd
    }

    private func freePort() -> (fd: Int32, port: Int)? {
        for port in 44100...44150 {
            if let fd = listen(on: port) { return (fd, port) }
        }
        return nil
    }

    func testAcceptingPortIsDetected() throws {
        guard let (fd, port) = freePort() else { throw XCTSkip("no free port") }
        defer { close(fd) }
        XCTAssertTrue(PortReadiness.isAccepting(port: port))
    }

    func testClosedPortIsNot() {
        XCTAssertFalse(PortReadiness.isAccepting(port: 44199))
    }

    func testWaitSucceedsWhenListenerAppearsLate() async throws {
        let port = 44175
        Task.detached {
            try? await Task.sleep(nanoseconds: 400_000_000)
            _ = self.listen(on: port) // leaked fd, process-lifetime — fine in tests
        }
        let ready = await PortReadiness.waitUntilAccepting(port: port, timeout: 5)
        XCTAssertTrue(ready)
    }

    func testWaitTimesOutOnSilence() async {
        let started = Date()
        let ready = await PortReadiness.waitUntilAccepting(port: 44198, timeout: 1)
        XCTAssertFalse(ready)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
}

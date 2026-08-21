import XCTest
@testable import Portside

final class AdoptionTests: XCTestCase {

    private func detected(
        pid: Int32, port: Int, cwd: String = "/repo",
        recipe: AdoptionRecipe? = AdoptionRecipe(name: "app", directory: "/repo", command: "npm run dev")
    ) -> DetectedServer {
        DetectedServer(
            pid: pid, port: port, pgid: pid, processName: "node",
            commandLine: nil, cwd: cwd, adoption: recipe
        )
    }

    private func select(
        _ servers: [DetectedServer],
        claimed: Set<String> = [],
        suppressed: Set<pid_t> = [],
        tombstoned: Set<String> = [],
        existing: Set<String> = []
    ) -> [(recipe: AdoptionRecipe, port: Int)] {
        Matching.adoptionSelections(
            detected: servers,
            isClaimed: { claimed.contains($0.id) },
            suppressedPids: suppressed,
            isTombstoned: { tombstoned.contains($0.directory + "|" + $0.command) },
            isDuplicate: { existing.contains($0.directory + "|" + $0.command) }
        )
    }

    func testAdoptsUnclaimedServer() {
        let picks = select([detected(pid: 1, port: 3000)])
        XCTAssertEqual(picks.count, 1)
        XCTAssertEqual(picks[0].port, 3000)
    }

    func testOneEntryPerPidTakesLowestPort() {
        let picks = select([
            detected(pid: 1, port: 24678), // HMR socket
            detected(pid: 1, port: 5173),
        ])
        XCTAssertEqual(picks.count, 1)
        XCTAssertEqual(picks[0].port, 5173)
    }

    func testExtraPortsOfClaimedPidsAreSkipped() {
        // pid 1 already claimed via its main port — its HMR socket must not
        // spawn a new entry.
        let main = detected(pid: 1, port: 5173)
        let hmr = detected(pid: 1, port: 24678)
        XCTAssertTrue(select([main, hmr], claimed: [main.id]).isEmpty)
    }

    func testSuppressedPidsAreSkipped() {
        XCTAssertTrue(select([detected(pid: 9, port: 3000)], suppressed: [9]).isEmpty)
    }

    func testTombstonedRecipesStayRemoved() {
        XCTAssertTrue(select(
            [detected(pid: 1, port: 3000)],
            tombstoned: ["/repo|npm run dev"]
        ).isEmpty)
    }

    func testExistingEntriesAreNotDuplicated() {
        XCTAssertTrue(select(
            [detected(pid: 1, port: 3000)],
            existing: ["/repo|npm run dev"]
        ).isEmpty)
    }

    func testWithinBatchDuplicatesCollapse() {
        // concurrently: two processes, same cwd, same shared script — one entry.
        let picks = select([
            detected(pid: 1, port: 3000),
            detected(pid: 2, port: 3001),
        ])
        XCTAssertEqual(picks.count, 1)
        XCTAssertEqual(picks[0].port, 3000)
    }

    func testDistinctRecipesInOneDirectoryBothAdopt() {
        // Same monorepo root, different commands (web + api) — two entries.
        let web = AdoptionRecipe(name: "repo", directory: "/repo", command: "pnpm run dev")
        let api = AdoptionRecipe(name: "repo", directory: "/repo", command: "pnpm run api")
        let picks = select([
            detected(pid: 1, port: 3000, recipe: web),
            detected(pid: 2, port: 3001, recipe: api),
        ])
        XCTAssertEqual(picks.count, 2)
    }

    func testRecipelessServersAreNeverAdopted() {
        XCTAssertTrue(select([detected(pid: 1, port: 3000, recipe: nil)]).isEmpty)
    }
}

final class ModelsTests: XCTestCase {

    func testAbbreviatingHome() {
        let home = NSHomeDirectory()
        XCTAssertEqual(home.abbreviatingHome, "~")
        XCTAssertEqual((home + "/Code/app").abbreviatingHome, "~/Code/app")
        // Component boundary: a sibling user's home must not become "~2".
        XCTAssertEqual((home + "2/Code").abbreviatingHome, home + "2/Code")
        XCTAssertEqual("/opt/x".abbreviatingHome, "/opt/x")
    }
}

final class SingleInstanceTests: XCTestCase {

    func testAcquireSucceedsAndContentionFails() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("portside-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }

        XCTAssertTrue(SingleInstance.acquire(baseDirectory: base),
                      "first acquire must succeed")
        // flock is per-open-file-description: a second open of the same lock
        // file contends even within one process.
        XCTAssertFalse(SingleInstance.acquire(baseDirectory: base),
                       "second acquire must detect the running instance")
    }
}

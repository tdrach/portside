import Darwin
import XCTest
@testable import Portside

final class ScannerIntegrationTests: XCTestCase {

    /// Binds a real listener and verifies the full scan pipeline finds it,
    /// resolves our cwd via syscalls, and refuses to build an adoption recipe
    /// for a temp-directory server.
    func testScanFindsOurOwnListener() throws {
        // Work from a darwin-temp cwd: real scan integration AND proof the
        // adoption boundary holds (nothing under /var/folders is adoptable).
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("portside-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let originalCwd = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(tempDir.path)
        defer {
            FileManager.default.changeCurrentDirectoryPath(originalCwd)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let (fd, port) = try bindListener()
        defer { close(fd) }

        let found = (PortScanner().scan() ?? []).first {
            $0.pid == getpid() && $0.port == port
        }
        guard let found else {
            return XCTFail("scan did not find our listener on port \(port)")
        }

        XCTAssertEqual(found.pgid, getpgid(getpid()))
        XCTAssertNotNil(found.cwd)
        XCTAssertEqual(
            Matching.canonicalPath(found.cwd!),
            Matching.canonicalPath(tempDir.path)
        )
        XCTAssertNil(found.adoption,
                     "temp-dir servers must never become saved entries")
    }

    func testListeningPidsVerifiesLiveListeners() throws {
        let (fd, _) = try bindListener()
        defer { close(fd) }
        let result = PortScanner.listeningPids(among: [getpid(), 99_999_999])
        XCTAssertTrue(result.contains(getpid()))
        XCTAssertFalse(result.contains(99_999_999))
    }

    func testResolvesExecutable() throws {
        XCTAssertTrue(PortScanner.resolvesExecutable("/bin/ls", cwd: "/"))
        XCTAssertTrue(PortScanner.resolvesExecutable("ls", cwd: "/"))
        XCTAssertFalse(PortScanner.resolvesExecutable("surely-not-a-tool-xyz", cwd: "/"))
        XCTAssertFalse(PortScanner.resolvesExecutable("", cwd: "/"))
        // Proctitle-rewritten garbage: spaces make it unresolvable.
        XCTAssertFalse(PortScanner.resolvesExecutable(
            "puma 6.4.2 (tcp://0.0.0.0:3000)", cwd: "/"
        ))

        // Relative paths resolve against the server's own directory.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("portside-exec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true
        )
        let script = dir.appendingPathComponent("bin/serve")
        try "#!/bin/sh".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(PortScanner.resolvesExecutable("bin/serve", cwd: dir.path))
        XCTAssertFalse(PortScanner.resolvesExecutable("bin/other", cwd: dir.path))
    }

    func testAdoptionRecipeQuotesArgvFallback() {
        // No package.json in cwd → argv fallback, shell-quoted.
        let recipe = PortScanner.adoptionRecipe(
            cwd: NSHomeDirectory() + "/Code/fake-app-for-test",
            argv: ["/bin/ls", "My Docs"]
        )
        XCTAssertEqual(recipe?.command, "/bin/ls 'My Docs'")
    }

    func testAdoptionRecipeRejectsUnresolvableArgv() {
        XCTAssertNil(PortScanner.adoptionRecipe(
            cwd: NSHomeDirectory() + "/Code/fake-app-for-test",
            argv: ["puma 6.4.2 (tcp://0.0.0.0:3000)"]
        ))
    }

    func testAdoptionRecipeRejectsBlockedDirectories() {
        XCTAssertNil(PortScanner.adoptionRecipe(cwd: "/", argv: ["/bin/ls"]))
        XCTAssertNil(PortScanner.adoptionRecipe(cwd: nil, argv: ["/bin/ls"]))
        XCTAssertNil(PortScanner.adoptionRecipe(
            cwd: NSHomeDirectory() + "/Library/Caches", argv: ["/bin/ls"]
        ))
    }

    // MARK: - Helpers

    private func bindListener() throws -> (fd: Int32, port: Int) {
        for port in 43211...43261 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
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
            if bound == 0, listen(fd, 1) == 0 {
                return (fd, port)
            }
            close(fd)
        }
        throw XCTSkip("no free port in test range")
    }
}

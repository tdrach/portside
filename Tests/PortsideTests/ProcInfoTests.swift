import Darwin
import XCTest
@testable import Portside

final class ProcInfoTests: XCTestCase {

    private func procArgsBuffer(argc: Int32, execPath: String, args: [String], env: [String]) -> Data {
        var data = Data()
        withUnsafeBytes(of: argc.littleEndian) { data.append(contentsOf: $0) }
        data.append(Data(execPath.utf8)); data.append(0)
        data.append(contentsOf: [0, 0, 0]) // NUL padding after exec path
        for arg in args { data.append(Data(arg.utf8)); data.append(0) }
        for entry in env { data.append(Data(entry.utf8)); data.append(0) }
        return data
    }

    func testParsesSyntheticBuffer() {
        let buffer = procArgsBuffer(
            argc: 2, execPath: "/bin/echo",
            args: ["echo", "hi there"], env: ["PATH=/usr/bin"]
        )
        XCTAssertEqual(ProcInfo.parseProcArgs(buffer), ["echo", "hi there"])
    }

    func testEnvironmentIsNotMistakenForArguments() {
        let buffer = procArgsBuffer(
            argc: 1, execPath: "/usr/bin/python3",
            args: ["python3"], env: ["SECRET=hunter2", "HOME=/Users/x"]
        )
        XCTAssertEqual(ProcInfo.parseProcArgs(buffer), ["python3"])
    }

    func testZeroArgcReturnsNil() {
        let buffer = procArgsBuffer(argc: 0, execPath: "/bin/x", args: [], env: [])
        XCTAssertNil(ProcInfo.parseProcArgs(buffer))
    }

    func testAbsurdArgcReturnsNil() {
        let buffer = procArgsBuffer(argc: 100_000, execPath: "/bin/x", args: ["x"], env: [])
        XCTAssertNil(ProcInfo.parseProcArgs(buffer))
    }

    func testTruncatedBufferReturnsPartialArgs() {
        // argc claims 3 but the buffer only carries 2 complete args.
        let buffer = procArgsBuffer(argc: 3, execPath: "/bin/x", args: ["a", "b"], env: [])
        XCTAssertEqual(ProcInfo.parseProcArgs(buffer), ["a", "b"])
    }

    func testEnvShapedArgvZeroIsRejected() {
        // Empty argv[0] makes its NUL look like padding, shifting an env
        // entry into slot 0 — must be detected, not misparsed as a command.
        let buffer = procArgsBuffer(
            argc: 1, execPath: "/bin/x", args: [], env: ["SECRET=hunter2"]
        )
        XCTAssertNil(ProcInfo.parseProcArgs(buffer))
    }

    func testTinyBufferReturnsNil() {
        XCTAssertNil(ProcInfo.parseProcArgs(Data([1, 0])))
    }

    // MARK: - Live syscalls against our own process

    func testLiveArgumentsOfSelf() {
        let args = ProcInfo.arguments(of: getpid())
        XCTAssertNotNil(args)
        XCTAssertFalse(args!.isEmpty)
        XCTAssertFalse(args![0].isEmpty)
    }

    func testLiveWorkingDirectoryOfSelf() {
        let cwd = ProcInfo.workingDirectory(of: getpid())
        XCTAssertNotNil(cwd)
        XCTAssertEqual(
            Matching.canonicalPath(cwd!),
            Matching.canonicalPath(FileManager.default.currentDirectoryPath)
        )
    }

    func testLiveProcessGroupOfSelf() {
        XCTAssertGreaterThan(ProcInfo.processGroup(of: getpid()), 0)
    }

    func testRootOwnedProcessIsUnreadable() {
        // launchd (pid 1) belongs to root — proc_pidinfo must fail cleanly.
        XCTAssertNil(ProcInfo.workingDirectory(of: 1))
    }

    func testNonexistentPidReturnsNil() {
        XCTAssertNil(ProcInfo.arguments(of: 99_999_999))
        XCTAssertNil(ProcInfo.workingDirectory(of: 99_999_999))
    }
}

// MARK: - Memory sampling

extension ProcInfoTests {
    func testResidentBytesOfSelfIsPlausible() {
        let bytes = ProcInfo.residentBytes(of: getpid())
        // A Swift test runner is comfortably over 1 MB and under 100 GB.
        XCTAssertGreaterThan(bytes, 1 << 20)
        XCTAssertLessThan(bytes, 100 << 30)
    }

    func testResidentBytesOfDeadPidIsZero() {
        // Spawn and reap a child so its pid is known-dead.
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { argv.forEach { free($0) } }
        XCTAssertEqual(posix_spawn(&pid, "/usr/bin/true", nil, nil, &argv, nil), 0)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        XCTAssertEqual(ProcInfo.residentBytes(of: pid), 0)
    }

    func testGroupIsAtLeastLeader() {
        let pid = getpid()
        let pgid = getpgid(pid)
        XCTAssertGreaterThanOrEqual(
            ProcInfo.groupResidentBytes(pgid: pgid),
            ProcInfo.residentBytes(of: pid))
    }
}

final class MemoryDisplayTests: XCTestCase {
    func testFormatting() {
        XCTAssertEqual(MemoryDisplay.format(200 << 20), "200 MB")
        XCTAssertEqual(MemoryDisplay.format(1_073_741_824), "1.0 GB")
        XCTAssertEqual(MemoryDisplay.format(UInt64(1.25 * 1_073_741_824)), "1.2 GB")
        XCTAssertEqual(MemoryDisplay.format(14 << 30), "14 GB")
        XCTAssertEqual(MemoryDisplay.format(512), "0 MB")
    }

    func testThresholdOrdering() {
        XCTAssertLessThan(MemoryDisplay.warnBytes, MemoryDisplay.alarmBytes)
    }
}

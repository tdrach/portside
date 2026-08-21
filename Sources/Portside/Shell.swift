import Foundation

/// Run a command synchronously and capture raw stdout. Call off the main
/// thread. A hung tool (wedged lsof, dead mount) is SIGKILLed at the timeout
/// so the scan pipeline can never freeze permanently.
func shellData(
    _ executable: String,
    _ arguments: [String],
    timeout: TimeInterval = 10
) -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        return Data()
    }

    let done = DispatchGroup()
    done.enter()
    var data = Data()
    DispatchQueue.global(qos: .utility).async {
        data = out.fileHandleForReading.readDataToEndOfFile()
        done.leave()
    }

    if done.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            kill(process.processIdentifier, SIGKILL)
        }
        // Only touch `data` once the reader thread has finished with it.
        guard done.wait(timeout: .now() + 3) != .timedOut else { return Data() }
    }
    process.waitUntilExit()
    return data
}

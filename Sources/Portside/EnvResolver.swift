import Darwin
import Foundation

/// Captures the user's real shell environment (PATH from nvm/mise/asdf/volta,
/// etc.) the way editors do: run the login shell once, interactively, and dump
/// its env. Commands still execute via zsh for stable POSIX syntax — only the
/// environment is taken from the user's shell.
enum EnvResolver {

    static let sentinel = "__PORTSIDE_ENV__"

    /// The user's login shell from the password database ($SHELL is unreliable
    /// for GUI apps).
    static func loginShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }

    /// Flags to run a one-off command in the given shell with rc files loaded.
    /// nil means the shell is unknown — skip capture rather than risk hanging.
    static func invocationFlags(forShell shellPath: String) -> [String]? {
        switch URL(fileURLWithPath: shellPath).lastPathComponent {
        case "zsh", "bash", "fish":
            return ["-l", "-i", "-c"]
        case "sh", "dash", "ksh":
            return ["-l", "-c"]
        case "tcsh", "csh":
            return ["-c"]
        default:
            return nil
        }
    }

    /// Runs the login shell and returns its environment, or nil on any failure
    /// (unknown shell, hang, missing PATH). Callers must treat nil as
    /// "fall back to the current process environment".
    static func capture(timeout: TimeInterval = 5) -> [String: String]? {
        let shell = loginShell()
        guard FileManager.default.isExecutableFile(atPath: shell),
              var arguments = invocationFlags(forShell: shell)
        else { return nil }

        // Sentinel separates rc-file noise (p10k, greetings) from the env dump.
        arguments.append("/usr/bin/printf '%s' '\(sentinel)'; /usr/bin/env -0")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe

        do { try process.run() } catch { return nil }

        let done = DispatchGroup()
        done.enter()
        var output = Data()
        DispatchQueue.global(qos: .utility).async {
            output = pipe.fileHandleForReading.readDataToEndOfFile()
            done.leave()
        }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            // A backgrounded rc-file child holding stdout open can stall the
            // read past env's output — kill the shell but still parse what
            // arrived; the sentinel tells us whether the dump is usable.
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                kill(process.processIdentifier, SIGKILL)
            }
            // Only touch `output` once the reader thread has finished with it.
            guard done.wait(timeout: .now() + 3) != .timedOut else { return nil }
        } else {
            process.waitUntilExit()
        }
        return parse(output)
    }

    /// Parses "<junk><sentinel>KEY=VALUE\0KEY=VALUE\0…". Exposed for tests.
    static func parse(_ data: Data) -> [String: String]? {
        guard let sentinelRange = data.range(of: Data(sentinel.utf8), options: .backwards) else {
            return nil
        }
        let block = data[sentinelRange.upperBound...]

        var environment: [String: String] = [:]
        for entry in block.split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let equals = text.firstIndex(of: "=") else { continue }
            let key = String(text[..<equals])
            guard isValidName(key) else { continue }
            environment[key] = String(text[text.index(after: equals)...])
        }
        guard environment["PATH"] != nil else { return nil }
        return environment
    }

    private static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

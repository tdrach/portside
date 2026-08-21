import Darwin
import Foundation

enum LaunchError: LocalizedError {
    case openLog(Int32)
    case spawn(Int32)

    var errorDescription: String? {
        switch self {
        case .openLog(let err): return "Couldn't open log file (errno \(err))"
        case .spawn(let err): return "Couldn't launch (\(String(cString: strerror(err))))"
        }
    }
}

/// Spawns server commands in their own process group so stop can kill the
/// whole tree (npm → node → esbuild workers) without touching this app.
enum Launcher {

    /// Rotate logs beyond this size at launch, keeping one .old generation.
    static let logRotationBytes: UInt64 = 5_000_000

    /// Runs `command` via zsh in `directory` with the given environment,
    /// stdout+stderr appended to `logURL` (created 0600). Returns the pid,
    /// which is also the pgid of a fresh process group.
    static func spawnShell(
        command: String,
        directory: String,
        logURL: URL,
        environment: [String: String]
    ) throws -> pid_t {
        rotateIfNeeded(logURL)

        let fd = open(logURL.path, O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LaunchError.openLog(errno) }
        defer { close(fd) }

        let stamp = ISO8601DateFormatter().string(from: Date())
        let header = "\n===== \(stamp)  $ \(command)  (in \(directory)) =====\n"
        Array(header.utf8).withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }

        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, fd, 1)
        posix_spawn_file_actions_adddup2(&fileActions, fd, 2)
        posix_spawn_file_actions_addchdir_np(&fileActions, directory)

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // New process group led by the child; close inherited fds except 0/1/2.
        var flags = Int16(POSIX_SPAWN_SETPGROUP)
        flags |= Int16(0x4000) // POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attr, flags)
        posix_spawnattr_setpgroup(&attr, 0)

        // zsh -c for stable POSIX syntax; the environment (captured from the
        // user's login shell at startup) carries their real PATH.
        let argv = ["/bin/zsh", "-l", "-c", command]
        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgv.append(nil)

        var cEnv: [UnsafeMutablePointer<CChar>?] = augmented(environment)
            .map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)

        defer {
            cArgv.forEach { if let p = $0 { free(p) } }
            cEnv.forEach { if let p = $0 { free(p) } }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/zsh", &fileActions, &attr, &cArgv, &cEnv)
        guard rc == 0 else { throw LaunchError.spawn(rc) }
        return pid
    }

    /// Ensures the standard tool locations are on PATH even if env capture
    /// failed, plus version-manager rescues for tools that only initialize in
    /// interactive rc files (lazy nvm being the classic).
    static func augmented(_ environment: [String: String]) -> [String: String] {
        var env = environment
        var path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let home = NSHomeDirectory()
        let fm = FileManager.default

        var extras = ["/usr/local/bin", "/opt/homebrew/sbin", "/opt/homebrew/bin"]
        for managed in [
            home + "/.volta/bin", home + "/.bun/bin", home + "/.deno/bin",
            home + "/.cargo/bin", home + "/.local/bin",
        ] where fm.fileExists(atPath: managed) {
            extras.append(managed)
        }
        if let nvmBin = latestNvmBin(home: home) {
            extras.append(nvmBin)
        }

        for extra in extras where !path.split(separator: ":").contains(Substring(extra)) {
            path = path + ":" + extra
        }
        env["PATH"] = path
        return env
    }

    /// The bin directory of the newest nvm-installed node, if any. nvm loads
    /// lazily in .zshrc, so env capture can miss it entirely.
    static func latestNvmBin(home: String) -> String? {
        let versionsDir = home + "/.nvm/versions/node"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: versionsDir)
        else { return nil }
        let best = entries
            .filter { $0.hasPrefix("v") }
            .max { semverParts($0).lexicographicallyPrecedes(semverParts($1)) }
        return best.map { versionsDir + "/" + $0 + "/bin" }
    }

    /// "v20.11.1" → [20, 11, 1] for comparison.
    static func semverParts(_ version: String) -> [Int] {
        version.dropFirst().split(separator: ".").map { Int($0) ?? 0 }
    }

    private static func rotateIfNeeded(_ logURL: URL) {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: logURL.path),
              let size = attributes[.size] as? UInt64,
              size > logRotationBytes
        else { return }
        let oldURL = logURL.deletingPathExtension().appendingPathExtension("old.log")
        try? fm.removeItem(at: oldURL)
        try? fm.moveItem(at: logURL, to: oldURL)
    }

    /// SIGTERM the whole process group.
    static func terminateGroup(_ pgid: pid_t) {
        kill(-pgid, SIGTERM)
    }
}

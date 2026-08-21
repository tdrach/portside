import Darwin
import Foundation

/// Guesses a start command for a directory from project files.
/// Read-only: never writes into the user's directory, never follows symlinks,
/// never opens anything that could block (FIFOs, devices, huge files).
enum CommandGuess {

    static func guess(directory: String) -> String? {
        packageJSONGuess(directory: directory) ?? projectFileGuess(directory: directory)
    }

    static func packageJSONGuess(directory: String) -> String? {
        guard let data = safeReadRegularFile(directory + "/package.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: Any]
        else { return nil }

        let runner = packageRunner(near: directory)
        for key in ["dev", "start", "serve", "preview"] where scripts[key] != nil {
            if runner == "npm" {
                return key == "start" ? "npm start" : "npm run \(key)"
            }
            return "\(runner) run \(key)"
        }
        return nil
    }

    /// Picks the package manager by lockfile, walking up toward the repo root —
    /// monorepo workspaces keep the lockfile at the root, not in the package.
    static func packageRunner(near directory: String) -> String {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
        for _ in 0..<6 {
            let path = dir.path
            if fm.fileExists(atPath: path + "/bun.lockb") || fm.fileExists(atPath: path + "/bun.lock") {
                return "bun"
            }
            if fm.fileExists(atPath: path + "/pnpm-lock.yaml") { return "pnpm" }
            if fm.fileExists(atPath: path + "/yarn.lock") { return "yarn" }
            if fm.fileExists(atPath: path + "/package-lock.json") { return "npm" }
            if fm.fileExists(atPath: path + "/.git") { break }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return "npm"
    }

    /// Non-Node conventions, consulted only when package.json gives nothing.
    /// These beat persisting a proctitle-rewritten argv (Rails/puma) or a
    /// temp build artifact path (go run).
    static func projectFileGuess(directory: String) -> String? {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: directory + "/bin/dev") {
            return "bin/dev"
        }
        if fm.fileExists(atPath: directory + "/Gemfile"),
           fm.isExecutableFile(atPath: directory + "/bin/rails") {
            return "bin/rails server"
        }
        if fm.fileExists(atPath: directory + "/manage.py") {
            return fm.isExecutableFile(atPath: directory + "/.venv/bin/python")
                ? ".venv/bin/python manage.py runserver"
                : "python3 manage.py runserver"
        }
        return nil
    }

    /// Reads a file only if it is a regular file under the size cap.
    /// O_NONBLOCK + O_NOFOLLOW mean a FIFO or symlink planted at this path can
    /// never hang the scanner or redirect the read.
    static func safeReadRegularFile(_ path: String, maxBytes: Int = 1_048_576) -> Data? {
        var linkStat = stat()
        guard lstat(path, &linkStat) == 0,
              (linkStat.st_mode & S_IFMT) == S_IFREG,
              linkStat.st_size <= maxBytes
        else { return nil }

        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var openStat = stat()
        guard fstat(fd, &openStat) == 0, (openStat.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while data.count <= maxBytes {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        return data
    }
}

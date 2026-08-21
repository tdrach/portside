import Darwin
import Foundation

/// Persists saved servers to ~/Library/Application Support/Portside/ and owns
/// the per-server log directory. This directory tree is the ONLY place
/// Portside ever writes — never inside a user's repo.
final class ServerStore {

    /// A removed server's identity. Auto-adoption never resurrects these —
    /// otherwise removing a supervised/auto-restarting server would be an
    /// unwinnable loop. Cleared when the user re-adds the same recipe.
    struct Tombstone: Codable, Equatable {
        var directory: String
        var command: String
    }

    private let dirURL: URL
    private let fileURL: URL
    private let legacyURL: URL
    private let tombstonesURL: URL
    private let projectsURL: URL
    let logsDir: URL

    /// `baseDirectory` is injectable for tests; defaults to Application Support.
    init(baseDirectory: URL? = nil) {
        let base = baseDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dirURL = base.appendingPathComponent("Portside", isDirectory: true)
        fileURL = dirURL.appendingPathComponent("servers.json")
        legacyURL = dirURL.appendingPathComponent("projects.json")
        tombstonesURL = dirURL.appendingPathComponent("tombstones.json")
        // NOT "projects.json" — that name is the legacy migration source
        // that load() still reads for pre-rename installs.
        projectsURL = dirURL.appendingPathComponent("server-projects.json")
        logsDir = dirURL.appendingPathComponent("logs", isDirectory: true)
        Self.ensureRealDirectory(dirURL)
        Self.ensureRealDirectory(logsDir)
    }

    /// Refuses to treat a symlink (or plain file) as one of our directories —
    /// a planted link would otherwise redirect every write we make into a
    /// location the attacker chose. Quarantines the impostor instead.
    static func ensureRealDirectory(_ url: URL) {
        var linkStat = stat()
        if lstat(url.path, &linkStat) == 0 {
            if (linkStat.st_mode & S_IFMT) == S_IFDIR {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: url.path
                )
                return
            }
            // A leftover .quarantined from an earlier attack must not make
            // the move fail (createDirectory would then silently succeed
            // THROUGH the still-present symlink). Clear it; if the move
            // still fails, deleting the impostor (a link/file, per lstat —
            // never a real directory) is the safe fallback.
            let quarantine = url.appendingPathExtension("quarantined")
            try? FileManager.default.removeItem(at: quarantine)
            do {
                try FileManager.default.moveItem(at: url, to: quarantine)
            } catch {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    // MARK: - Servers

    func load() -> [Server] {
        switch decode([Server].self, from: fileURL) {
        case .success(let servers):
            return servers
        case .corrupt:
            // Never silently overwrite a file the user may have hand-edited —
            // set it aside so nothing is lost, then start empty.
            let backup = dirURL.appendingPathComponent("servers.json.corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            return []
        case .missing:
            break
        }
        // Migrate from the pre-rename file; the old file is left in place.
        if case .success(let servers) = decode([Server].self, from: legacyURL) {
            save(servers)
            return servers
        }
        return []
    }

    func save(_ servers: [Server]) {
        writeJSON(servers, to: fileURL)
    }

    // MARK: - Projects

    func loadProjects() -> [Project] {
        switch decode([Project].self, from: projectsURL) {
        case .success(let projects):
            return projects
        case .corrupt:
            let backup = dirURL.appendingPathComponent("server-projects.json.corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: projectsURL, to: backup)
            return []
        case .missing:
            return []
        }
    }

    func saveProjects(_ projects: [Project]) {
        writeJSON(projects, to: projectsURL)
    }

    // MARK: - Tombstones

    func loadTombstones() -> [Tombstone] {
        if case .success(let tombstones) = decode([Tombstone].self, from: tombstonesURL) {
            return tombstones
        }
        return []
    }

    func saveTombstones(_ tombstones: [Tombstone]) {
        writeJSON(Array(tombstones.suffix(200)), to: tombstonesURL)
    }

    // MARK: - Logs

    func logURL(for server: Server) -> URL {
        // Port (or a stable id fragment) disambiguates same-named servers so
        // two entries never interleave one log file.
        let suffix = server.port.map { "-\($0)" }
            ?? "-" + server.id.uuidString.prefix(6).lowercased()
        return logsDir.appendingPathComponent(slug(server.name) + suffix + ".log")
    }

    func oldLogURL(for server: Server) -> URL {
        logURL(for: server).deletingPathExtension().appendingPathExtension("old.log")
    }

    func slug(_ name: String) -> String {
        let mapped = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "server" : collapsed
    }

    // MARK: - Plumbing

    private enum DecodeResult<T> {
        case success(T)
        case corrupt
        case missing
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) -> DecodeResult<T> {
        guard let data = try? Data(contentsOf: url) else { return .missing }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { return .corrupt }
        return .success(value)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        }
    }
}

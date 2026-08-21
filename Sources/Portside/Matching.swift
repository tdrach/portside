import Darwin
import Foundation

/// Pure matching logic between saved servers and detected listeners.
/// Kept free of AppModel state so it's directly testable.
enum Matching {

    /// Canonical form for directory comparison: tilde-expanded, symlinks
    /// resolved, case-folded (APFS is case-insensitive by default).
    static func canonicalPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(expanded, &buffer) != nil {
            return String(cString: buffer).lowercased()
        }
        return expanded.lowercased()
    }

    /// Which saved server (if any) does this detected listener belong to?
    /// Precedence: a run Portside started (matched by process group — robust
    /// against port drift), then configured port, then directory for
    /// port-less entries.
    ///
    /// A port match alone is NOT enough when the listener's cwd is known and
    /// contradicts the saved directory — another project squatting the port
    /// must never light up (or get killed through) someone else's row.
    static func claimant(
        of detected: DetectedServer,
        saved: [Server],
        managedPgids: [pid_t: UUID],
        canonical: (String) -> String
    ) -> UUID? {
        if detected.pgid > 0, let owner = managedPgids[detected.pgid] {
            return owner
        }

        // A port match counts ONLY when corroborated by the working
        // directory. cwd "/" or nil is not "probably ours" — every
        // launchd-spawned app has cwd "/" (ControlCenter holds ports
        // 5000/7000), and a claim authorizes Stop to signal the process.
        if let cwd = detected.cwd, cwd != "/", !cwd.isEmpty {
            let canonicalCwd = canonical(cwd)
            if let corroborated = saved.first(where: {
                $0.port == detected.port && canonical($0.directory) == canonicalCwd
            }) {
                return corroborated.id
            }
        }

        if let cwd = detected.cwd {
            let canonicalCwd = canonical(cwd)
            if let byDirectory = saved.first(where: {
                $0.port == nil && canonical($0.directory) == canonicalCwd
            }) {
                return byDirectory.id
            }
        }
        return nil
    }

    /// Pure adoption selection: which detected servers become saved entries
    /// this round. One per pid (lowest port), skipping claimed/suppressed/
    /// tombstoned/duplicate recipes — including duplicates within the batch
    /// (concurrently/turbo spawn several listeners sharing one script).
    static func adoptionSelections(
        detected: [DetectedServer],
        isClaimed: (DetectedServer) -> Bool,
        suppressedPids: Set<pid_t>,
        isTombstoned: (AdoptionRecipe) -> Bool,
        isDuplicate: (AdoptionRecipe) -> Bool
    ) -> [(recipe: AdoptionRecipe, port: Int)] {
        var byPid: [pid_t: DetectedServer] = [:]
        for server in detected {
            guard server.adoption != nil,
                  !suppressedPids.contains(server.pid),
                  !isClaimed(server),
                  !detected.contains(where: { $0.pid == server.pid && isClaimed($0) })
            else { continue }
            if let existing = byPid[server.pid], existing.port <= server.port {
                continue
            }
            byPid[server.pid] = server
        }

        var selections: [(recipe: AdoptionRecipe, port: Int)] = []
        var batchKeys = Set<String>()
        for candidate in byPid.values.sorted(by: { $0.port < $1.port }) {
            guard let recipe = candidate.adoption,
                  !isTombstoned(recipe),
                  !isDuplicate(recipe)
            else { continue }
            let key = recipe.directory + "\u{0}" + recipe.command
            guard batchKeys.insert(key).inserted else { continue }
            selections.append((recipe, candidate.port))
        }
        return selections
    }

    /// Directories whose servers should never be auto-saved as restartable
    /// entries: app internals, system paths, package caches. They still show
    /// as ephemeral rows while running.
    static func isAdoptableDirectory(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let canonical = canonicalPath(path)
        guard canonical != "/", !canonical.isEmpty else { return false }

        let canonicalHome = canonicalPath(home)
        // A server whose cwd is $HOME itself is never a project.
        if canonical == canonicalHome { return false }

        var blockedPrefixes = [
            "/applications", "/system", "/library", "/usr", "/bin", "/sbin",
            "/opt", "/nix", "/cores", "/private/var/db", "/private/etc",
            "/private/var/folders",
        ]
        blockedPrefixes.append(canonicalHome + "/library")

        if blockedPrefixes.contains(where: { canonical == $0 || canonical.hasPrefix($0 + "/") }) {
            return false
        }
        if canonical.contains("/node_modules/") || canonical.hasSuffix("/node_modules") {
            return false
        }
        if canonical.contains(".app/") {
            return false
        }
        // Hidden directories (~/.colima, ~/.cache, ~/.local/share/…) hold
        // tool state, not repos.
        if canonical.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
            return false
        }
        return true
    }
}

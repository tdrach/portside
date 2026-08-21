import Darwin
import Foundation

/// One Portside per user — two instances would double-scan and re-adopt
/// removed entries. flock-based so it also covers `swift run` and renamed
/// bundles, which a bundle-identifier check misses.
enum SingleInstance {
    private static var lockFD: Int32 = -1

    /// `baseDirectory` is injectable for tests; defaults to Application Support.
    static func acquire(baseDirectory: URL? = nil) -> Bool {
        let base = (baseDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("Portside", isDirectory: true)
        ServerStore.ensureRealDirectory(base) // never lock through a symlink

        lockFD = open(
            base.appendingPathComponent(".lock").path,
            O_CREAT | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600
        )
        guard lockFD >= 0 else { return true } // can't lock → don't block launch

        // Brief retry so quit-and-relaunch doesn't race the dying instance.
        for _ in 0..<5 {
            if flock(lockFD, LOCK_EX | LOCK_NB) == 0 { return true }
            // Only contention means another instance; flock-less filesystems
            // and other errors must not permanently refuse to launch.
            if errno != EWOULDBLOCK { return true }
            usleep(300_000)
        }
        return false
    }
}

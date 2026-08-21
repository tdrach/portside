import CLibProc
import Darwin
import Foundation

/// Reads process metadata via syscalls — no subprocess spawns.
enum ProcInfo {

    /// The process's current working directory, via proc_pidinfo.
    /// Returns nil for processes we can't inspect (other users, gone, kernel).
    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let written = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard written == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        return path.isEmpty ? nil : path
    }

    /// The process's original argv via sysctl KERN_PROCARGS2. Unlike ps output,
    /// this is a real argument array — safe to re-quote — and immune to
    /// proctitle rewriting.
    static func arguments(of pid: pid_t) -> [String]? {
        var argmax = 0
        var argmaxSize = MemoryLayout<Int>.size
        var mibMax: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mibMax, 2, &argmax, &argmaxSize, nil, 0) == 0, argmax > 0 else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: argmax)
        var bufferSize = argmax
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &bufferSize, nil, 0) == 0,
              bufferSize > MemoryLayout<Int32>.size
        else { return nil }

        return parseProcArgs(Data(buffer[0..<bufferSize]))
    }

    /// KERN_PROCARGS2 layout: Int32 argc | exec_path NUL | NUL padding |
    /// argv[0] NUL argv[1] NUL … | environment…  (exposed for tests)
    static func parseProcArgs(_ data: Data) -> [String]? {
        guard data.count > 4 else { return nil }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) }
        guard argc > 0, argc < 4096 else { return nil }

        var index = 4
        // Skip the exec path string…
        while index < data.count, data[index] != 0 { index += 1 }
        // …and the NUL padding after it.
        while index < data.count, data[index] == 0 { index += 1 }

        var args: [String] = []
        var current: [UInt8] = []
        while index < data.count, args.count < Int(argc) {
            let byte = data[index]
            if byte == 0 {
                args.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
            index += 1
        }
        guard !args.isEmpty else { return nil }
        // A pathological empty argv[0] makes its NUL look like padding and
        // shifts an environment entry into slot 0. A program name is never
        // NAME=value shaped — reject rather than misparse.
        if args[0].range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) != nil {
            return nil
        }
        return args
    }

    /// Process group id; 0 if unavailable.
    /// Resident memory of one process, in bytes. 0 when the pid is gone
    /// or unreadable (we only ever inspect same-uid processes).
    static func residentBytes(of pid: pid_t) -> UInt64 {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let written = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        guard written == size else { return 0 }
        return info.pti_resident_size
    }

    /// Resident memory of an entire process group, in bytes — a dev server
    /// is a tree (npm → node → workers), and the group is what a row
    /// actually costs. Falls back to the leader alone if the group can't
    /// be listed.
    static func groupResidentBytes(pgid: pid_t) -> UInt64 {
        let capacity = Int32(4096)
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let written = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pgid), &pids,
                                    capacity * Int32(MemoryLayout<pid_t>.size))
        guard written > 0 else { return residentBytes(of: pgid) }
        let count = Int(written) / MemoryLayout<pid_t>.size
        var total: UInt64 = 0
        for pid in pids.prefix(count) where pid > 0 {
            total += residentBytes(of: pid)
        }
        return total
    }

    static func processGroup(of pid: pid_t) -> pid_t {
        let pgid = getpgid(pid)
        return pgid > 0 ? pgid : 0
    }
}

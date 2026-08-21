import Darwin
import Foundation

/// Non-blocking TCP readiness probes, used to gate ordered project starts
/// (API before frontend). Pure and testable; never touches AppModel state.
enum PortReadiness {

    /// One connect attempt to loopback:port with a bounded wait. Probes
    /// IPv4 then IPv6 — a member bound only to ::1 must not turn every
    /// ordered gate into the full timeout.
    static func isAccepting(port: Int, timeout: TimeInterval = 0.25) -> Bool {
        connectLoopback(port: port, family: AF_INET, timeout: timeout)
            || connectLoopback(port: port, family: AF_INET6, timeout: timeout)
    }

    private static func connectLoopback(
        port: Int, family: Int32, timeout: TimeInterval
    ) -> Bool {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let rc: Int32
        if family == AF_INET6 {
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = in_port_t(UInt16(clamping: port).bigEndian)
            addr.sin6_addr = in6addr_loopback
            rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(clamping: port).bigEndian)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return false }
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
        return soError == 0
    }

    /// Polls until the port accepts, the deadline passes, or the task is
    /// cancelled (stop mid-sequence must not keep launching members).
    static func waitUntilAccepting(
        port: Int, timeout: TimeInterval, pollEvery: TimeInterval = 0.3
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !Task.isCancelled {
            let accepting = await Task.detached(priority: .utility) {
                isAccepting(port: port)
            }.value
            if accepting { return true }
            try? await Task.sleep(nanoseconds: UInt64(pollEvery * 1_000_000_000))
        }
        return false
    }
}
